# Plan: New option --build-dir DIR

## Overview

Add a `--build-dir DIR` option to the `run` subcommand that allows users to specify a custom build directory instead of using a temporary directory. This is useful for debugging purposes - users can inspect intermediate build artifacts (preprocessed `.ml` files, `.cmo`, `.cmi` files, and the final executable).

## Current Behavior

In `bin/main.ml:213`, the `run` function creates a temporary directory:
```ocaml
let build_dir = Filename.temp_dir "mach" "" in
```

This temporary directory is never explicitly cleaned up (it relies on OS cleanup), and users cannot easily inspect its contents.

## Proposed Changes

### 1. Add `build_dir_arg` Cmdliner argument

Add a new optional argument after the existing `store_arg`:

```ocaml
let build_dir_arg =
  Arg.(value & opt (some string) None & info ["build-dir"] ~docv:"DIR"
    ~doc:"Build directory for intermediate files (useful for debugging). If not specified, a temporary directory is used.")
```

### 2. Modify `run` function signature

Change the `run` function to accept an optional build directory:

```ocaml
let run store_dir build_dir_opt script_path args =
  let build_dir = match build_dir_opt with
    | Some dir ->
        ensure_dir_rec dir;
        dir
    | None ->
        Filename.temp_dir "mach" ""
  in
  (* rest unchanged *)
```

Key behaviors:
- If `--build-dir` is provided: use that directory, create it if it doesn't exist
- If not provided: use a temporary directory (current behavior)
- The custom build directory is NOT cleaned up after execution (user's responsibility)

### 3. Update `run_cmd` to include `build_dir_arg`

```ocaml
let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run $ store_arg $ build_dir_arg $ script_arg $ args_arg)
```

## Files to Modify

- `bin/main.ml` - Add argument definition, modify `run` function

## Testing

Create a test in `test/` directory that:
1. Runs a script with `--build-dir ./mybuild`
2. Verifies the build directory contains expected files (`.ml`, `.cmo`, `.cmi`, `a.out`)
3. Verifies the script executes correctly

Example test case:
```
Create a script, run with --build-dir, verify artifacts exist
  $ mkdir -p build_test
  $ cat > hello.ml << 'EOF'
  > let () = print_endline "hello"
  > EOF
  $ mach run --build-dir ./my_build hello.ml
  hello
  $ ls ./my_build
  Hello.cmi
  Hello.cmo
  Hello.ml
  a.out
```

## Implementation Steps

1. Add `build_dir_arg` Cmdliner argument definition (after line 280)
2. Modify `run` function signature to accept `build_dir_opt` parameter (line 212)
3. Add logic at the start of `run` to handle custom vs temporary build dir
4. Update `run_cmd` Term to include `build_dir_arg` (line 291)
5. Add cram test for the new option
6. Run tests to verify

## Edge Cases

- **Directory doesn't exist**: Create it with `ensure_dir_rec`
- **Directory exists with old files**: fail
- **Relative vs absolute paths**: Both should work; relative paths resolve from current working directory
- **Permission errors**: Let OCaml raise standard exceptions (user will see error)
