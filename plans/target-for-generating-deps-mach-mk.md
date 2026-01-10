# Plan: Target for generating deps' mach.mk

## Problem Analysis

Currently in `bin/main.ml`, the `run` function:

1. Calls `resolve_deps` which recursively traverses the **entire** dependency tree using DFS (lines 105-130)
2. Calls `List.iter write_mach_mk all_deps` (line 316) to eagerly generate `mach.mk` files for **all** dependencies before running Make

This is inefficient because:
- We traverse the whole dependency tree upfront in OCaml code
- All `mach.mk` files must exist before Make starts
- We duplicate work that Make's include mechanism could handle

## Desired Behavior

- Only find **immediate** dependencies (no recursion)
- Add a Makefile target for generating `mach.mk` files of dependencies
- Let Make handle recursive dependency resolution via its include mechanism

## Implementation Plan

### Step 1: Add new `mach configure` subcommand

Add a new subcommand `mach configure <mod.ml>` that **only** generates `mach.mk` for the given module:

```ocaml
let configure source_path =
  let source_path = normalize_path source_path in
  let parsed = parse_and_preprocess source_path in
  let module_name = module_name_of_path source_path |> String.uncapitalize_ascii in
  let build_dir = ensure_dir_rec (default_build_dir source_path) in
  let resolved_requires = List.map (resolve_path ~relative_to:source_path) parsed.requires in
  let m : ocaml_module = { source = parsed; module_name; build_dir; resolved_requires } in
  let mach_mk_file = Filename.(build_dir / "mach.mk") in
  write_file mach_mk_file (mach_mk m)
```

CLI definition:
```ocaml
let configure_cmd =
  let doc = "Generate mach.mk for a module" in
  let info = Cmd.info "configure" ~doc in
  Cmd.v info Term.(const configure $ source_arg)
```

### Step 2: Modify mach_mk to include rules for generating deps' mach.mk

Currently `mach_mk` does:
```ocaml
let mk = List.fold_left (fun mk req_path ->
  let req_build_dir = default_build_dir req_path in
  include_ Filename.(req_build_dir / "mach.mk") mk
) mk m.resolved_requires in
```

Add a rule **before** the include that calls `mach configure`:
```ocaml
let mk = List.fold_left (fun mk req_path ->
  let req_build_dir = default_build_dir req_path in
  let mach_mk_path = Filename.(req_build_dir / "mach.mk") in
  let recipe = Printf.sprintf "mach configure %s" req_path in
  mk
  |> rule mach_mk_path [req_path] (Some recipe)
  |> include_ mach_mk_path
) mk m.resolved_requires in
```

This generates:
```makefile
/path/to/dep/build/mach.mk: /path/to/dep/source.ml
	mach configure /path/to/dep/source.ml
include /path/to/dep/build/mach.mk
```

When Make tries to include a non-existent `mach.mk`, it will first run the rule to create it.

### Step 3: Simplify run function

Remove the full tree traversal and only handle the entry script:

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

  (* Only parse the entry script, don't recurse *)
  let parsed = parse_and_preprocess script_path in
  let resolved_requires = List.map (resolve_path ~relative_to:script_path) parsed.requires in

  let script = {
    source = parsed;
    module_name = module_name_of_path script_path |> String.uncapitalize_ascii;
    build_dir;
    resolved_requires;
  } in

  let exe_path = Filename.(build_dir / "a.out") in

  (* Only generate mach.mk for the script itself *)
  write_mach_mk script;

  (* Generate Makefile and run make - same as before *)
  ...
```

### Step 4: Remove unused functions

After the refactoring, `collect_deps` and `resolve_deps` become unused and can be removed.

## Summary of Subcommands

After this change:
- `mach configure <mod.ml>` - Only generates `mach.mk` for the module (new)
- `mach preprocess <mod.ml>` - Generates preprocessed `.ml` and `includes.args` (existing)
- `mach run <script.ml>` - Builds and runs the script (existing, simplified)

## Edge Cases

1. **Circular dependencies**: With lazy generation, Make would detect cycles via "recursive dependency" errors when including `mach.mk` files.

2. **First run vs incremental**: On first run, Make will generate all `mach.mk` files as needed. On subsequent runs, if source files haven't changed, `mach.mk` files won't be regenerated.

## Testing

1. Existing tests should pass (test_deps_recur.t, test_build_dir.t, etc.)
2. The behavior should be identical from user perspective
3. Can verify lazy generation by checking that dependencies' `mach.mk` files are created by Make (not by mach run directly)

---

## Implementation Summary (Completed)

### Changes Made

1. **Added `mach configure` subcommand** (`bin/main.ml:288-296`)
   - New subcommand that only generates `mach.mk` for a given module
   - CLI definition added at line 395-398

2. **Extended Makefile DSL** (`bin/main.ml:110-169`)
   - Added `sinclude_` for silent includes (ignores missing files)
   - Added `ifndef` and `endif` for conditional guards

3. **Modified `mach_mk` function** (`bin/main.ml:217-236`)
   - For each dependency, generates a guarded rule to create its `mach.mk`
   - Uses `sinclude_` to silently include the dependency's `mach.mk`
   - Guards prevent duplicate rules when same dep is required by multiple modules

4. **Simplified `run` function** (`bin/main.ml:309-334`)
   - Removed call to `resolve_deps` (no more full DFS traversal)
   - Only parses the entry script for immediate dependencies
   - Only generates `mach.mk` for the script itself

5. **Removed unused code**
   - Deleted `visit_state` type
   - Deleted `collect_deps` function
   - Deleted `resolve_deps` function

### Generated Makefile Structure

Each `mach.mk` now generates:
```makefile
ifndef DEP_CONFIGURE_RULE
DEP_CONFIGURE_RULE := 1
/dep/build/mach.mk: /dep/source.ml
	mach configure /dep/source.ml
endif
-include /dep/build/mach.mk
```

This allows Make to lazily generate `mach.mk` files as needed via its include-and-remake mechanism.

### All tests pass
