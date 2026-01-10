# Plan: Remove --build-dir option

## Summary

Remove the `--build-dir` CLI option from the `mach run` command. The rationale is that users can already control the root directory for mach builds by setting the `$XDG_CONFIG_HOME` environment variable, making the `--build-dir` option redundant.

## Current State

### Code Analysis

In `bin/main.ml`:

1. **`build_dir_arg`** (lines 353-355): Cmdliner argument definition for `--build-dir`
2. **`run` function** (lines 292-346): Takes `build_dir_opt` parameter and handles it:
   - If `Some dir`: Validates the directory doesn't exist, creates it, and uses it
   - If `None`: Uses the default build directory derived from script path via `default_build_dir`
3. **`run_cmd`** (lines 367-370): Wires `build_dir_arg` into the `run` subcommand

### Tests Using --build-dir

- `test/test_build_dir.t`: Specifically tests the `--build-dir` option functionality

### Tests NOT Using --build-dir

- `test/test_build_dir_auto.t`: Tests auto-derived build directory (uses `$XDG_CONFIG_HOME`)
- `test/test_simple.t`
- `test/test_deps_recur.t`
- `test/test_dup_require.t`
- `test/test_shebang.t`
- `test/test_verbose.t`

## Implementation Steps

### Step 1: Modify `bin/main.ml`

1. **Remove `build_dir_arg`** definition (lines 353-355)

2. **Simplify `run` function signature** (line 292):
   - Change from: `let run verbose build_dir_opt script_path args =`
   - To: `let run verbose script_path args =`

3. **Simplify build_dir logic** (lines 294-301):
   - Remove the `match build_dir_opt` handling
   - Always use `default_build_dir script_path`
   - Remove the check that fails if directory already exists (the default behavior allows reuse)

4. **Update `run_cmd`** (lines 367-370):
   - Remove `build_dir_arg` from the Term

### Step 2: Update Tests

1. **Delete `test/test_build_dir.t`**: This test specifically tests the `--build-dir` option which we're removing

2. **Verify `test/test_build_dir_auto.t` still works**: This test demonstrates the preferred approach using `$XDG_CONFIG_HOME`

### Step 3: Run Tests

Run `dune test` to ensure all remaining tests pass.

## Code Changes Detail

### In `bin/main.ml`:

**Before (lines 292-301):**
```ocaml
let run verbose build_dir_opt script_path args =
  let script_path = normalize_path script_path in
  let build_dir = match build_dir_opt with
    | Some dir ->
        if Sys.file_exists dir
        then failwith (Printf.sprintf "Build directory already exists: %s" dir)
        else normalize_path (ensure_dir_rec dir)
    | None ->
        ensure_dir_rec (default_build_dir script_path)
  in
```

**After:**
```ocaml
let run verbose script_path args =
  let script_path = normalize_path script_path in
  let build_dir = ensure_dir_rec (default_build_dir script_path) in
```

**Before (lines 353-355):**
```ocaml
let build_dir_arg =
  Arg.(value & opt (some string) None & info ["build-dir"] ~docv:"DIR"
    ~doc:"Build directory for intermediate files (useful for debugging). If not specified, a temporary directory is used.")
```

**After:** (delete entirely)

**Before (lines 367-370):**
```ocaml
let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run $ verbose_arg $ build_dir_arg $ script_arg $ args_arg)
```

**After:**
```ocaml
let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run $ verbose_arg $ script_arg $ args_arg)
```

## Verification

After implementation:
1. `dune build` should succeed
2. `dune test` should pass (6 tests remaining after removing `test_build_dir.t`)

## Risk Assessment

**Low risk**:
- This is a cleanup task removing a debugging-only feature
- The primary functionality (auto-derived build directory with `$XDG_CONFIG_HOME` support) is preserved
- All other tests continue to verify the main use cases

---

## Implementation Summary (Completed)

### Changes Made

1. **`bin/main.ml`**:
   - Removed `build_dir_arg` Cmdliner definition
   - Simplified `run` function: removed `build_dir_opt` parameter, now always uses `default_build_dir`
   - Updated `run_cmd` to remove `build_dir_arg` from Term

2. **Tests**:
   - Deleted `test/test_build_dir.t` (tested the removed option)
   - Updated `test/test_dup_require.t`: removed `--build-dir ./build` from command
   - Updated `test/test_verbose.t`: simplified to verify verbose mode outputs `+ make all` (using grep to handle variable build paths)

### Verification

All 6 remaining tests pass:
- `test_build_dir_auto.t`
- `test_deps_recur.t`
- `test_dup_require.t`
- `test_shebang.t`
- `test_simple.t`
- `test_verbose.t`
