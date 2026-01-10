# Plan: Build Dependencies in Their Respective Build Directories

## Current Behavior

Currently, dependencies are compiled in a store directory with hash-based caching:
- Store at `~/.config/mach/store/<hash>/`
- Hash computation using SHA256
- Complex caching logic

## Desired Behavior

Simplify: each dependency builds in its own build directory, no store, no hashing. Skip compilation if .cmo/.cmi already exist.

## Implementation Steps

### Step 1: Remove hashing code

Delete:
- `sha256_of_string` function
- `compute_hash` function
- `find_in_store` function

### Step 2: Simplify `dep_info` type

```ocaml
type dep_info = {
  source: parsed_source;
  module_name: string;
  build_dir: string;
  resolved_requires: string list;
}
```

### Step 3: Simplify `resolve_deps`

Remove `store_dir` parameter, no hash computation:

```ocaml
let resolve_deps script_path =
  let parsed_deps, entry_parsed = collect_deps script_path in
  let deps = List.map (fun source ->
    let module_name = module_name_of_path source.path in
    let module_base = String.uncapitalize_ascii module_name in
    let resolved_requires = List.map (resolve_path ~relative_to:source.path) source.requires in
    let build_dir = default_build_dir source.path in
    { source; module_name = module_base; build_dir; resolved_requires }
  ) parsed_deps in
  (deps, entry_parsed)
```

### Step 4: Update `run` function

Remove `store_dir` parameter. Update `write_includes_args` to point to build directories:

```ocaml
let write_includes_args ~build_dir ~dep_map requires =
  let args_file = Filename.(build_dir / "includes.args") in
  Out_channel.with_open_text args_file (fun oc ->
    List.iter (fun req_path ->
      match Hashtbl.find_opt dep_map req_path with
      | Some dep ->
          output_string oc "-I\n";
          output_line oc dep.build_dir
      | None -> assert false
    ) requires
  );
  args_file
```

### Step 5: Update dependency compilation loop

Check if .cmo/.cmi exist, skip compilation if so:

```ocaml
let dep_cmos =
  List.map (fun dep ->
    let build_dir = ensure_dir_rec dep.build_dir in
    let cmo_path = Filename.(build_dir / dep.module_name ^ ".cmo") in
    let cmi_path = Filename.(build_dir / dep.module_name ^ ".cmi") in
    begin if Sys.file_exists cmo_path && Sys.file_exists cmi_path then ()
    else
      let args_file = write_includes_args ~build_dir ~dep_map dep.resolved_requires in
      let source_ml = Filename.(build_dir / dep.module_name ^ ".ml") in
      write_file source_ml dep.source.preprocessed;
      compile ~verbose ~args_file ~output_cmo:cmo_path source_ml
    end;
    cmo_path
  ) deps
```

### Step 6: Remove store-related CLI

- Remove `--store` option
- Remove `store-cleanup` command
- Remove `deps` command (or simplify to just list dependencies without hash/store info)

### Step 7: Remove `default_store_dir` and related code

Clean up all store-related utilities.

## Summary of Deletions

- `sha256_of_string`
- `compute_hash`
- `find_in_store`
- `default_store_dir`
- `store_cleanup` function and command
- `store_arg` CLI option
- `deps` command (or simplify it)
- `hash` and `in_store` fields from `dep_info`

## Test Plan

1. Run `dune test` - update tests that reference store/hash
2. Verify dependencies build in their own build directories
3. Verify script runs correctly with dependencies

## Files Changed

- `bin/main.ml` - All changes in this single file

## Summary of What Was Done

### Code Changes in `bin/main.ml`:

1. **Removed hashing code:**
   - Deleted `sha256_of_string` function
   - Deleted `compute_hash` function
   - Deleted `find_in_store` function

2. **Simplified `dep_info` type:**
   - Removed `hash` and `in_store` fields
   - Added `build_dir` field

3. **Simplified `resolve_deps`:**
   - Removed `store_dir` parameter
   - Removed hash computation
   - Added `build_dir` computation using `default_build_dir`

4. **Updated `run` function:**
   - Removed `store_dir` parameter
   - Updated `write_includes_args` to take `~build_dir` parameter and point `-I` to `dep.build_dir`
   - Updated dependency compilation to build in `dep.build_dir` and check for existing `.cmo/.cmi`

5. **Removed store-related CLI:**
   - Removed `default_store_dir` function
   - Removed `store_arg` CLI option
   - Removed `deps` function and `deps_cmd`
   - Removed `store_cleanup` function, `remove_dir`, and `store_cleanup_cmd`

### Test Changes:

- Updated all tests to remove `--store` references
- Deleted `test_deps.t` (tested removed `deps` command)
- Updated `test_build_dir.t` to verify dependency build directories
