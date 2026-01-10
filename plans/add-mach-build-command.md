# Plan: Add `mach build` command

## Goal

Add a `mach build SCRIPT` subcommand that builds the script without executing it.

## Current State

The `run` function in `bin/main.ml:194-215` does the following:
1. Calls `configure script_path` to generate `mach.mk` files for the script and its dependencies
2. Writes a root `Makefile` that links everything together
3. Invokes `make` to build the executable
4. Calls `Unix.execv` to execute the built binary

## Implementation

### Approach

Refactor the `run` function to extract the build logic into a separate `build` function, then:
- `build` - configures and compiles without executing
- `run` - calls `build` and then executes

### Changes to `bin/main.ml`

1. **Extract `build` function** (lines 194-212):
   ```ocaml
   let build verbose script_path =
     let script = configure script_path in
     let exe_path = Filename.(script.build_dir / "a.out") in
     write_file Filename.(script.build_dir / "Makefile") Makefile.(
       let mk = create () in
       var mk "MACH_OBJS" "";
       include_ mk Filename.(script.build_dir / "mach.mk");
       rule mk ".PHONY" ["all"] None;
       rule mk "all" [exe_path] None;
       link_ocaml_module mk script ~exe_path;
       contents mk
     );
     (* Run make *)
     let make_cmd = if verbose then "make all" else "make -s all" in
     let cmd = sprintf "%s -C %s" make_cmd (Filename.quote script.build_dir) in
     if verbose then eprintf "+ %s\n%!" cmd;
     let exit_code = Sys.command cmd in
     if exit_code <> 0 then
       failwith (sprintf "Build failed with exit code %d" exit_code);
     exe_path
   ```

2. **Simplify `run` function**:
   ```ocaml
   let run verbose script_path args =
     let exe_path = build verbose script_path in
     let argv = Array.of_list (exe_path :: args) in
     Unix.execv exe_path argv
   ```

3. **Add `build_cmd` Cmdliner command** (after `run_cmd`):
   ```ocaml
   let build_cmd =
     let doc = "Build an OCaml script without executing it" in
     let info = Cmd.info "build" ~doc in
     let f verbose script_path = ignore (build verbose script_path) in
     Cmd.v info Term.(const f $ verbose_arg $ script_arg)
   ```

4. **Register the new command** (line 258):
   ```ocaml
   Cmd.group ~default info [run_cmd; build_cmd; preprocess_cmd; configure_cmd]
   ```

### Test

Add `test/test_build.t`:
```
Isolate mach config to a test dir:
  $ export XDG_CONFIG_HOME=$PWD/.config

Prepare source files:
  $ cat << 'EOF' > hello.ml
  > print_endline "hello"
  > EOF

Build without running:
  $ mach build ./hello.ml

Check the executable was created:
  $ ls .config/mach/build/*__hello.ml/a.out
  .config/mach/build/*__hello.ml/a.out

Run the executable manually:
  $ .config/mach/build/*__hello.ml/a.out
  hello
```

## Summary

- Extract build logic from `run` into a new `build` function
- Add `mach build` subcommand that calls `build` but does not execute
- Add cram test to verify `mach build` works correctly

## Completed

Implementation completed successfully:

1. Extracted `build` function from `run` in `bin/main.ml:194-213`
   - `build verbose script_path` returns the `exe_path`

2. Simplified `run` function (`bin/main.ml:215-218`) to call `build` and then execute

3. Added `build_cmd` Cmdliner command (`bin/main.ml:239-243`) with `--verbose` flag and `SCRIPT` argument

4. Registered `build_cmd` in the command group (`bin/main.ml:267`)

5. Added `test/test_build.t` cram test that verifies:
   - `mach build` compiles without running
   - The executable `a.out` is created in the build directory
   - The executable can be run manually

All tests pass.
