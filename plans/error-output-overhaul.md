# Error Output Overhaul

## Problem Statement

When builds fail, mach currently shows a lot of noise from make/ninja output. The user sees:
- OCaml compiler error messages (useful)
- make/ninja internal messages (noise)
- Build rule names and paths (noise)

For example, from `test/test_error_in_dep.t`:
```
File "$TESTCASE_ROOT/lib.ml", line 3, characters 6-12:
Error: This constant has type string but an expression was expected of type
         int
make: *** [$TESTCASE_ROOT/.config/mach/build/__Users__...] Error 2
mach: internal error, uncaught exception:
```

## Solution Design

Create a filtering mechanism that:
1. Wraps compiler commands to prefix their output with `>>>`
2. Filters make/ninja output to only show lines starting with `>>>`

### Components

#### 1. `mach format-cmd-output` Subcommand

A new subcommand that reads from stdin and writes to stderr, prefixing each line with `>>>`.

```
Usage: COMMAND ARGS... 2>&1 | mach format-cmd-output
```

Implementation:
- Read lines from stdin
- Prefix each line with `>>>`
- Write to stderr
- Exit 0

Note: The `2>&1` redirect is needed because OCaml compiler errors go to stderr. The exit code of the pipeline comes from the command, not the formatter (due to shell semantics, or we can use `set -o pipefail` in ninja/make).

#### 2. Modify Build File Generation

Wrap compiler commands in Makefile/Ninja generation to pipe through the formatter.

In `lib/mach_lib.ml`, the `configure_backend` function generates rules like:
```
ocamlc -bin-annot -c ... -o %s %s
ocamlopt -bin-annot -c ... -o %s %s
```

These need to become (using `${MACH}` variable defined in root build file):
```
ocamlc -bin-annot -c ... -o %s %s 2>&1 | ${MACH} format-cmd-output
ocamlopt -bin-annot -c ... -o %s %s 2>&1 | ${MACH} format-cmd-output
```

Commands that need wrapping:
- `ocamlc` - compiles `.mli` to `.cmi`
- `ocamlopt` - compiles `.ml` to `.cmx` and links

Commands that don't need wrapping (no meaningful output):
- `touch` - creates empty args files
- `echo` - writes to args files
- `rm -f` - removes files
- `printf` - writes to args files
- `ocamlfind query` - writes to args files

#### 3. Modify Build Execution

In `build_exn`, capture make/ninja output and filter it:
- Read output line by line
- For lines starting with `>>>`, strip prefix and print to stderr
- Discard other lines

### Implementation Steps

1. **Add `format-cmd-output` subcommand to `bin/mach.ml`**
   - Create a function that reads stdin and prefixes each line with `>>>` to stderr
   - Register it as a cmdliner subcommand

2. **Modify build file generation (`lib/mach_lib.ml`, `lib/makefile.ml`, `lib/ninja.ml`)**
   - Define `MACH` variable in root build file (Makefile/build.ninja)
   - Add pipefail support (shell flags for Make, bash wrapper for Ninja)
   - Wrap `ocamlc` and `ocamlopt` invocations with `| ${MACH} format-cmd-output`

3. **Modify `lib/mach_lib.ml` build_exn function**
   - Replace `Sys.command cmd` with process spawning
   - Read and filter stdout/stderr line by line
   - Print only lines starting with `>>>` (after stripping prefix)

4. **Update tests**
   - Update `test/test_error_reporting.t` - should now show clean error output
   - Update `test/test_error_in_dep.t` - should show clean error output

### Detailed Implementation

#### Step 1: `format-cmd-output` subcommand

Add to `bin/mach.ml`:

```ocaml
let format_cmd_output_cmd =
  let doc = "Read stdin and prefix each line with >>> to stderr" in
  let info = Cmd.info "format-cmd-output" ~doc in
  let f () =
    try while true do
      let line = input_line stdin in
      Printf.eprintf ">>>%s\n%!" line
    done with End_of_file -> ()
  in
  Cmd.v info Term.(const f $ const ())
```

#### Step 2: Wrap compiler commands

In `configure_backend`, wrap ocamlc/ocamlopt calls by appending the pipe. Use `${MACH}` which works for both Makefile and Ninja:

```ocaml
(* Generic for both backends *)
let wrap_cmd recipe = sprintf "%s 2>&1 | ${MACH} format-cmd-output" recipe

(* For Ninja backend - need bash -o pipefail wrapper *)
let wrap_cmd_ninja recipe = sprintf "bash -o pipefail -c '%s 2>&1 | $${MACH} format-cmd-output'" recipe
```

Apply to:
- Line 105: `ocamlc -bin-annot -c ...` → wrap
- Line 106: `ocamlopt -bin-annot -c ...` → wrap
- Line 119: `ocamlopt -o ...` → wrap
- Line 124: `ocamlopt -o ...` → wrap

**Important for exit codes**:
- **Makefile**: Add `SHELL = /bin/bash` and `.SHELLFLAGS = -o pipefail -c` at the top of generated Makefiles
- **Ninja**: Wrap the command in `bash -o pipefail -c "..."` since Ninja uses `/bin/sh` by default

**Mach executable variable**: Define `MACH` variable in the root build file pointing to the mach executable path. Use `${MACH}` in commands instead of hardcoding the path. This syntax works for both Makefile and Ninja, keeping the code generic.

#### Step 3: Filter build output

Replace in `build_exn`:

```ocaml
let run_build_filtered cmd =
  let open Unix in
  let (stdout_read, stdout_write) = pipe () in
  let (stderr_read, stderr_write) = pipe () in
  let pid = create_process "/bin/sh" [|"/bin/sh"; "-c"; cmd|] stdin stdout_write stderr_write in
  close stdout_write;
  close stderr_write;
  let read_and_filter fd =
    let ic = in_channel_of_descr fd in
    (try while true do
      let line = input_line ic in
      if String.length line >= 3 && String.sub line 0 3 = ">>>" then
        prerr_endline (String.sub line 3 (String.length line - 3))
    done with End_of_file -> ());
    close_in ic
  in
  read_and_filter stdout_read;
  read_and_filter stderr_read;
  let _, status = waitpid [] pid in
  match status with
  | WEXITED 0 -> ()
  | _ -> Mach_error.user_errorf "build failed"
```

### Testing

Update `test/test_error_reporting.t`:
```
Test error when build fails:

  $ cat << 'EOF' > bad_script.ml
  > let () = this_is_not_valid
  > EOF

  $ mach run ./bad_script.ml
  File "$TESTCASE_ROOT/bad_script.ml", line 1, characters 9-25:
  Error: Unbound value this_is_not_valid
  mach: build failed
  [1]
```

The make/ninja noise should be gone.

### Edge Cases

1. **Multiline error messages**: OCaml errors span multiple lines. The formatter prefixes each line, so they're all preserved.

2. **Concurrent output**: make/ninja run commands in parallel. Each command's stderr goes through its own formatter instance, so `>>>` prefixes are correctly applied per-line.

3. **Empty output**: If a command produces no output, the formatter just exits immediately.

4. **Pipeline exit codes**: With `pipefail` enabled, the pipeline exit code is from the failing command (compiler), not the formatter. This is what we want.

### Files to Modify

1. `bin/mach.ml` - Add `format-cmd-output` subcommand
2. `lib/mach_lib.ml` - Wrap compiler commands, filter build output
3. `lib/makefile.ml` - Add `SHELL` and `.SHELLFLAGS` for pipefail support
4. `lib/ninja.ml` - Wrap commands with `bash -o pipefail -c`
5. `test/test_error_reporting.t` - Update expected output
6. `test/test_error_in_dep.t` - Update expected output (or keep disabled)
