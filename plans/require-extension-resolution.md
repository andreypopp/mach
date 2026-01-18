# Plan: Change require syntax to omit file extensions

## Overview

Change the syntax for require directives from including file extensions:

```ocaml
#require "./mod.ml"
```

to omitting file extensions:

```ocaml
#require "./mod"
```

Mach will automatically resolve the path by trying `.ml` first, then `.mlx` file extensions.

## Current Implementation

The current implementation in `lib/mach_module.ml` has two key functions:

### 1. `resolve_require` (lines 27-35)
```ocaml
let resolve_require ~source_path ~line path =
  let path =
    if Filename.is_relative path
    then Filename.concat (Filename.dirname source_path) path
    else path
  in
  try Unix.realpath path
  with Unix.Unix_error (err, _, _) ->
    Mach_error.user_errorf "%s:%d: %s: %s" source_path line path (Unix.error_message err)
```

**Current behavior**: Expects the full filename with extension (e.g., `./lib.ml`). Uses `Unix.realpath` directly on the path, which fails if the file doesn't exist.

### 2. `extract_requires_exn` (lines 37-56)
```ocaml
let extract_requires_exn source_path : requires:string with_loc list * libs:string with_loc list =
  (* ... parses #require directives ... *)
  let resolved = resolve_require ~source_path ~line:line_num req in
  (* ... *)
```

**Current behavior**: Parses `#require "..."` directives and calls `resolve_require` on file paths (those starting with `/`, `./`, or `../`).

## Implementation Steps

### Step 1: Modify `resolve_require` function in `lib/mach_module.ml`

Change the function to try multiple file extensions when resolving a require path.

**New implementation:**

```ocaml
let resolve_require ~source_path ~line path =
  let base_path =
    if Filename.is_relative path
    then Filename.concat (Filename.dirname source_path) path
    else path
  in
  (* Try .ml first, then .mlx *)
  let candidates = [base_path ^ ".ml"; base_path ^ ".mlx"] in
  let rec find_file = function
    | [] ->
        Mach_error.user_errorf "%s:%d: %s: No such file or directory" source_path line path
    | candidate :: rest ->
        if Sys.file_exists candidate then
          Unix.realpath candidate
        else
          find_file rest
  in
  find_file candidates
```

**Key changes:**
1. Append `.ml` and `.mlx` extensions to the base path
2. Try each candidate in order (`.ml` first, then `.mlx`)
3. Use `Sys.file_exists` to check if file exists before calling `Unix.realpath`
4. Return the first matching file, or error if none found
5. Error message now refers to the base path without extension

### Step 2: Update all test files

Update all test files that use `#require` with file paths to use the new syntax without extensions.

**Files to update:**

| File | Current | New |
|------|---------|-----|
| `test/test_simple.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_deps_recur.t` | `#require "./lib_b.ml"`, `#require "./lib_a.ml"` | `#require "./lib_b"`, `#require "./lib_a"` |
| `test/test_mlx.t` | `#require "./helper.ml"`, `#require "./widget.mlx"` | `#require "./helper"`, `#require "./widget"` |
| `test/test_dup_require.t` | `#require "./lib.ml"`, `#require "./a.ml"`, `#require "./b.ml"` | `#require "./lib"`, `#require "./a"`, `#require "./b"` |
| `test/test_mach_lsp.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_error_reporting.t` | `#require "./missing_dep.ml"` | `#require "./missing_dep"` (and update expected error message) |
| `test/test_mli_basic.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_mli_add.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_mli_remove.t` | `#require "./lib.ml"` (x2) | `#require "./lib"` |
| `test/test_mli_abstract_type.t` | `#require "./counter.ml"` | `#require "./counter"` |
| `test/test_reconfigure.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_build_dir_auto.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_error_in_dep.t` | `#require "./lib.ml"`, `#require "./lib2.ml"` | `#require "./lib"`, `#require "./lib2"` |
| `test/test_dep_remove.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_dep_add.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_dep_modify.t` | `#require "./lib.ml"` | `#require "./lib"` |
| `test/test_dep_replace.t` | `#require "./old_lib.ml"`, `#require "./new_lib.ml"` | `#require "./old_lib"`, `#require "./new_lib"` |
| `test/test_dep_transitive_add.t` | `#require "./lib_a.ml"`, `#require "./lib_b.ml"` | `#require "./lib_a"`, `#require "./lib_b"` |
| `test/test_dep_transitive_remove.t` | `#require "./lib_b.ml"`, `#require "./lib_a.ml"` | `#require "./lib_b"`, `#require "./lib_a"` |
| `test/test_pp.t` | `#require "./lib.ml"` | `#require "./lib"` |

**Note:** Library requires (like `#require "cmdliner"` in `test/test_ocamlfind_lib.t`) should remain unchanged as they are not file paths.

### Step 3: Update error message in `test/test_error_reporting.t`

The error message format will change because we now report the base path without extension:

**Before:**
```
mach: $TESTCASE_ROOT/script.ml:1: $TESTCASE_ROOT/./missing_dep.ml: No such file or directory
```

**After:**
```
mach: $TESTCASE_ROOT/script.ml:1: ./missing_dep: No such file or directory
```

Note: The error message should show the path as the user wrote it (without the resolved directory prefix), making it clearer what was requested.

### Step 4: Run tests to verify

```bash
make test
```

## Design Considerations

### 1. Extension resolution order
- `.ml` is tried first, then `.mlx`
- This matches the common case where most files are `.ml`
- Consistent with how OCaml tools typically work

### 2. Error messages
- When no file is found, the error message shows the path as the user wrote it (without extension)
- This makes it clear what the user needs to create

### 3. Backward compatibility
- This is a breaking change - existing scripts with extensions will break
- However, the task explicitly requests this change
- Users will need to update their `#require` directives to remove extensions

### 4. Ambiguity handling
- If both `mod.ml` and `mod.mlx` exist, `.ml` wins
- This is deterministic and predictable
- Users who want the `.mlx` version when both exist would need to restructure their project

### 5. Absolute paths
- The resolution logic works the same for absolute paths (`/path/to/mod`)
- Extension is appended to form candidates

## Files to Modify

1. **`lib/mach_module.ml`** - Modify `resolve_require` function
2. **`test/*.t`** - Update all test files with file path requires (see list above)

## Testing

After implementation, run:
```bash
make test
```

All existing tests should pass with the updated syntax.
