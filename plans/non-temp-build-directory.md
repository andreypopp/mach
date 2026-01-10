# Plan: Non-temp Build Directory

## Feature Description

Change the build directory from a temporary directory to a persistent, script-path-derived location.

**Current behavior:**
- When `--build-dir` is not specified, `Filename.temp_dir "mach" ""` creates a temp directory
- Temp directories are not cleaned up (since `Unix.execv` replaces the process)
- Each run creates a new temp directory with a random name

**Desired behavior:**
- Derive build directory from script path: `~/.config/mach/build/<normalized-script-path>`
- Normalized script path: Replace `/` with `__` (e.g., `/Users/foo/script.ml` → `__Users__foo__script.ml`)
- If directory already exists, reuse it (don't fail)

## Implementation Steps

### 1. Add `config_dir` helper function

Extract the config directory logic from `default_store_dir` into a reusable function:

```ocaml
let config_dir () =
  match Sys.getenv_opt "XDG_CONFIG_HOME" with
  | Some dir -> dir
  | None -> Filename.(Sys.getenv "HOME" / ".config")
```

### 2. Refactor `default_store_dir`

Update to use the new `config_dir` function:

```ocaml
let default_store_dir () = Filename.(config_dir () / "mach" / "store")
```

### 3. Add `default_build_dir` function

Create a function that derives the build directory from the script path:

```ocaml
let default_build_dir script_path =
  let normalized = String.split_on_char '/' script_path |> String.concat "__" in
  Filename.(config_dir () / "mach" / "build" / normalized)
```

The normalization works as follows:
- `/Users/foo/script.ml` → Split on `/` → `[""; "Users"; "foo"; "script.ml"]`
- Join with `__` → `"__Users__foo__script.ml"`

### 4. Modify `run` function

Current code:
```ocaml
let run verbose store_dir build_dir_opt script_path args =
  let build_dir = match build_dir_opt with
    | Some dir ->
        if Sys.file_exists dir
        then failwith (Printf.sprintf "Build directory already exists: %s" dir)
        else ensure_dir_rec dir
    | None ->
        Filename.temp_dir "mach" ""
  in
  let script_path = normalize_path script_path in
  ...
```

New code:
```ocaml
let run verbose store_dir build_dir_opt script_path args =
  let script_path = normalize_path script_path in  (* Move this up *)
  let build_dir = match build_dir_opt with
    | Some dir ->
        if Sys.file_exists dir
        then failwith (Printf.sprintf "Build directory already exists: %s" dir)
        else ensure_dir_rec dir
    | None ->
        ensure_dir_rec (default_build_dir script_path)  (* Use derived dir *)
  in
  ...
```

Key changes:
1. Normalize `script_path` BEFORE computing `build_dir` (needed for path derivation)
2. Use `default_build_dir` when no explicit `--build-dir` is provided
3. `ensure_dir_rec` handles existing directories correctly (returns existing path)

### 5. Add test

Add a new cram test to verify:
1. Build directory is created at the derived location
2. Re-running the script reuses the same build directory

## Edge Cases

1. **Script path with spaces**: The `__` replacement doesn't affect spaces, so they're preserved
2. **Existing build directory**: `ensure_dir_rec` checks `Sys.file_exists` and returns early if exists
3. **Multiple scripts with same basename**: Full path is used, so they get different build directories

## Files to Modify

- `bin/main.ml`: Add functions and modify `run`
- `test/test_build_dir_auto.t` (new): Add test for auto-derived build directory

## Implementation Summary

### Changes Made

1. **Added `config_dir` and `default_build_dir` functions** (`bin/main.ml:10-17`)
   - `config_dir()`: Returns XDG config directory or `~/.config`
   - `default_build_dir(script_path)`: Derives build dir from normalized script path

2. **Fixed `ensure_dir_rec` for race condition** (`bin/main.ml:32-38`)
   - Added `try/with Unix.Unix_error (Unix.EEXIST, _, _)` to handle concurrent directory creation
   - This prevents failures when tests run in parallel or when multiple mach instances run simultaneously

3. **Modified `run` function** (`bin/main.ml:193-211`)
   - Moved `normalize_path script_path` before build_dir computation
   - Changed `None` case to use `ensure_dir_rec (default_build_dir script_path)` instead of `Filename.temp_dir`

4. **Refactored `default_store_dir`** (`bin/main.ml:297`)
   - Now uses shared `config_dir()` function

5. **Added test** (`test/test_build_dir_auto.t`)
   - Verifies build directory is created at XDG-derived location
   - Verifies re-running reuses the same build directory
   - Uses `XDG_CONFIG_HOME` env var to control test location

### All tests pass
