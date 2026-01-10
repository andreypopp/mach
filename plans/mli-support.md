# Plan: Support .mli Files

## Overview

Add support for `.mli` interface files. When a `.mli` file exists alongside a `.ml` file, we need to:
1. Compile the `.mli` to `.cmi` first
2. Compile the `.ml` to `.cmo` using that `.cmi`

## Current Behavior

Currently, the build process for each module:
1. Preprocesses `source.ml` → `build_dir/module.ml`
2. Compiles `build_dir/module.ml` → `build_dir/module.cmo` (also produces `.cmi`)

## Required Changes

### 1. Data Model Changes

Add an optional `mli_path` field to track interface files, rename source_path to `ml_path` for clarity:

```ocaml
type ocaml_module = {
  ml_path: string;
  mli_path: string option;  (* NEW: path to .mli if it exists *)
  module_name: string;
  build_dir: string;
  resolved_requires: string list;
}
```

Similarly, update `Mach_state.entry` to track `.mli` files (also rename `path`
to `ml_path` and `stat` to `ml_stat` for clarity):

```ocaml
type entry = {
  ml_path: string;
  mli_path: string option;  (* NEW *)
  ml_stat: file_stat;
  mli_stat: file_stat option;  (* NEW: stat for .mli *)
  requires: string list
}
```

### 2. Detection Logic

Add a helper to detect `.mli` files:

```ocaml
let mli_path_of_ml path =
  let base = Filename.remove_extension path in
  let mli = base ^ ".mli" in
  if Sys.file_exists mli then Some mli else None
```

### 3. State Cache Updates

Update `Mach_state` module:

- `collect`: Detect `.mli` files when collecting entries
- `is_fresh`: Also check `.mli` stat when validating freshness
- `read`/`write`: can detect if `.mli` for an `.ml` file by name, and fill `entry` accordingly.

The key insight for handling `.mli` removal: `is_fresh` should return `false` when:
- The `.mli` file was removed (entry has `mli_path` but file no longer exists)
- The `.mli` file was added (entry has no `mli_path` but file now exists)

### 4. Preprocess Updates

When preprocessing, also copy the `.mli` file to the build directory:

```ocaml
let preprocess build_dir source_path =
  let source_path = Unix.realpath source_path in
  let module_name = module_name_of_path source_path in
  let source_ml = Filename.(build_dir / module_name ^ ".ml") in
  (* Preprocess .ml as before *)
  Out_channel.with_open_text source_ml (fun oc ->
    In_channel.with_open_text source_path (fun ic ->
      preprocess_source oc ic));
  (* Handle .mli *)
  let mli_path = mli_path_of_ml source_path in
  let build_mli = Filename.(build_dir / module_name ^ ".mli") in
  match mli_path with
  | Some src_mli ->
    (* Copy .mli to build dir *)
    let content = In_channel.with_open_text src_mli In_channel.input_all in
    Out_channel.with_open_text build_mli (fun oc -> output_string oc content)
  | None ->
    (* Remove .mli from build dir if it exists (handles removal case) *)
    if Sys.file_exists build_mli then Sys.remove build_mli
```

### 5. Makefile Generation Updates

Update `configure_ocaml_module` and `compile_ocaml_module`:

**For modules WITH `.mli`:**
```makefile
# Configure: preprocess and generate .mli
module.ml: source.ml
	mach preprocess source.ml -o build_dir

# .mli is produced by preprocess, empty rule
module.mli: module.ml

# Compile .mli first to produce .cmi
module.cmi: module.mli includes.args <dep .cmi files>
	ocamlc -c -args includes.args -o module.cmi module.mli

# Compile .ml using the .cmi
module.cmo: module.ml module.cmi includes.args
	ocamlc -c -args includes.args -cmi-file module.cmi -o module.cmo module.ml
```

**For modules WITHOUT `.mli`:**
```makefile
# Same as current behavior
module.cmo: module.ml includes.args <dep .cmi files>
	ocamlc -c -args includes.args -o module.cmo module.ml

# empty rule
module.cmi: module.cmo
```

The `-intf-suffix .generated-cmi` flag tells `ocamlc` to not look for `.mli` files with the default `.mli` suffix, forcing it to use the existing `.cmi` we compiled from the `.mli`.

### 6. Implementation Steps

1. **Add `mli_path` field to `ocaml_module` type**
2. **Add `mli_path` and `mli_stat` fields to `Mach_state.entry` type**
3. **Add `mli_path_of_ml` helper function**
4. **Update `Mach_state.collect`** to detect and record `.mli` files
5. **Update `Mach_state.is_fresh`** to validate `.mli` freshness (including detection of added/removed `.mli`)
6. **Update `Mach_state.read/write`** to serialize `.mli` info
7. **Update `preprocess`** to copy/remove `.mli` files
8. **Update `make_ocaml_module_from_entry`** to populate `mli_path`
9. **Update `Makefile.configure_ocaml_module`** to declare `.mli` dependency
10. **Update `Makefile.compile_ocaml_module`** to handle both with/without `.mli` cases

### 7. Test Cases

Create `test/test_mli.t`:

**Test 1: Basic .mli support**
- Create `lib.ml` and `lib.mli` where `.mli` exposes a subset
- Create `main.ml` that uses `lib`
- Verify compilation works

**Test 2: Adding .mli to existing module**
- Start with just `lib.ml` and `main.ml`
- Run once
- Add `lib.mli`
- Run again - verify recompilation happens and works

**Test 3: Removing .mli from existing module**
- Start with `lib.ml`, `lib.mli`, and `main.ml`
- Run once
- Remove `lib.mli`
- Run again - verify recompilation happens and works

**Test 4: Type hiding via .mli**
- Create `lib.ml` with an implementation type
- Create `lib.mli` that makes the type abstract
- Verify the type is properly hidden

## Edge Cases

1. **`.mli` without `.ml`**: Not supported - we only look for `.mli` alongside existing `.ml` files
2. **Concurrent `.mli` modification**: Handled by state cache freshness check
3. **`.mli` in dependencies**: Each module handles its own `.mli` independently

### 8. Cleanup on .mli Removal (Discovered During Implementation)

When `.mli` is removed from source, we need to clean up stale build artifacts:
1. Remove `.mli` from build dir
2. Remove `.cmi` (was compiled from `.mli`)
3. Remove `.cmo` (was compiled with `-cmi-file`, didn't produce its own `.cmi`)

This cleanup happens in `configure` when state is not fresh:

```ocaml
let build_mli = Filename.(build_dir / m.module_name ^ ".mli") in
if Option.is_none m.mli_path && Sys.file_exists build_mli then begin
  Sys.remove build_mli;
  let build_cmi = Filename.(build_dir / m.module_name ^ ".cmi") in
  let build_cmo = Filename.(build_dir / m.module_name ^ ".cmo") in
  if Sys.file_exists build_cmi then Sys.remove build_cmi;
  if Sys.file_exists build_cmo then Sys.remove build_cmo
end
```

## Summary

The key changes are:
1. Track `.mli` files in state cache
2. Copy `.mli` to build directory during preprocessing
3. Generate correct Makefile rules based on `.mli` presence
4. Clean up `.mli`/`.cmi`/`.cmo` from build dir when source `.mli` is removed
5. Invalidate cache when `.mli` is added or removed
