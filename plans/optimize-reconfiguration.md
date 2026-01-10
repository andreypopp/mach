# Plan: Optimize Re-configuration Step

## Problem Statement

Currently, mach re-configures (regenerates Makefile and mach.mk files) on **any change** to any file in the dependency graph. This is inefficient because:

1. Simple content changes to `.ml` files don't require reconfiguration - Make/Ninja handles rebuilding based on file timestamps
2. Re-configuration wipes all build directories (`rm_rf`) and regenerates everything from scratch (see `configure` function at line 296-297)

## Current Implementation Analysis

Looking at `mach_lib.ml`:

### `Mach_state.is_fresh` (lines 139-152)
Checks if **any** file has changed (mtime/size) or if any `.mli` was added/removed. Returns a single boolean - no granularity about what changed.

### `configure` function (lines 287-310)
```ocaml
let configure ?(backend=Make) source_path =
  ...
  let state, is_fresh =
    match Mach_state.read state_path with
    | Some st when Mach_state.is_fresh st -> st, true
    | _ -> Mach_state.collect source_path, false
  in
  if not is_fresh then begin
    List.iter (fun entry -> rm_rf (build_dir_of entry.Mach_state.ml_path)) state.entries;
    mkdir_p build_dir;
    Mach_state.write state_path state
  end;
  ...
```

When state is not fresh:
1. **Wipes ALL build directories** - even if only one file changed
2. Regenerates ALL configuration files

## When Re-configuration is Actually Needed

### Changes that REQUIRE re-configuration:
1. **Dependency graph changes** (affects module's build rules):
   - A module gains/loses a `#require` directive → its `mach.mk` changes
   - This transitively affects dependents (need to update `includes.args`, link order)

2. **`.mli` addition/removal** (affects the module's build rules):
   - Without `.mli`: compile `.ml` → `.cmo` + `.cmi`
   - With `.mli`: compile `.mli` → `.cmi`, then `.ml` → `.cmo`

### Changes that DON'T require re-configuration:
1. **Content changes** to `.ml`/`.mli` without changing `#require` directives or `.mli` existence
   - Make/Ninja handles this via timestamp-based rebuild

## Proposed Solution

Replace `is_fresh : t -> bool` with a function that distinguishes between structural changes (requiring reconfiguration) and content-only changes (handled by Make):

```ocaml
val needs_reconfigure : t -> bool
```

Returns `true` if:
- Any file was removed from disk
- Any `.mli` was added or removed
- Any module's `#require` directives changed

Returns `false` if:
- Only content changed (mtime/size differ but structure is the same)

### Algorithm

For each entry in saved state:
1. Check if `.ml` file still exists → if not, needs reconfigure
2. Check if `.mli` existence changed (added or removed) → if so, needs reconfigure
3. If `.ml` mtime/size changed, re-parse `#require` directives and compare → if different, needs reconfigure
4. Otherwise, no structural change for this entry

If any entry needs reconfigure → return `true`
Otherwise → return `false` (let Make handle content rebuilds)

### Implementation

```ocaml
let needs_reconfigure state =
  List.exists (fun entry ->
    let ml_path = entry.ml_path in
    (* File removed? *)
    if not (Sys.file_exists ml_path) then true
    else
      (* .mli added or removed? *)
      let current_mli_exists = mli_path_of_ml_if_exists ml_path <> None in
      let saved_mli_exists = entry.mli_path <> None in
      if current_mli_exists <> saved_mli_exists then true
      else
        (* Check if requires changed (only if ml file changed) *)
        let current_stat = file_stat ml_path in
        let stat_changed =
          current_stat.mtime <> entry.ml_stat.mtime ||
          current_stat.size <> entry.ml_stat.size
        in
        if stat_changed then begin
          let current_requires = extract_requires ml_path in
          let current_requires = List.map (resolve_path ~relative_to:ml_path) current_requires in
          current_requires <> entry.requires
        end else
          false
  ) state.entries
```

### Update `configure` function

If `Mach.state` exists and `needs_reconfigure` returns `false`, the build files already exist from a previous run. We can skip regeneration entirely:

```ocaml
let configure ?(backend=Make) source_path =
  let source_path = Unix.realpath source_path in
  let build_dir = build_dir_of source_path in
  let state_path = Filename.(build_dir / "Mach.state") in

  let state, needs_reconfig =
    match Mach_state.read state_path with
    | None -> Mach_state.collect source_path, true
    | Some old_state ->
      if Mach_state.needs_reconfigure old_state then
        Mach_state.collect source_path, true
      else
        old_state, false
  in

  let root_module, exe_path =
    if needs_reconfig then begin
      List.iter (fun entry -> rm_rf (build_dir_of entry.Mach_state.ml_path)) state.entries;
      mkdir_p build_dir;
      (* Regenerate build files *)
      (match backend with
      | Make -> configure_backend (module Makefile) ~module_file:"mach.mk" ~root_file:"Makefile" state
      | Ninja -> configure_backend (module Ninja) ~module_file:"mach.ninja" ~root_file:"build.ninja" state);
      Mach_state.write state_path state
    end else begin
      (* Build files already exist, just compute paths *)
      let root_module = make_ocaml_module_from_entry state.root in
      let exe_path = Filename.(root_module.build_dir / "a.out") in
      root_module, exe_path
    end
  in
  state, root_module, exe_path
```

## Implementation Steps

1. Replace `Mach_state.is_fresh` with `Mach_state.needs_reconfigure` (inverted logic, checks for structural changes)
2. Update `configure` to only regenerate build files when `needs_reconfigure` returns `true`
3. Update tests if needed (existing tests should still pass)

## Testing Strategy

Existing tests should continue to pass. The behavior is:
- Structural changes (dep add/remove, .mli add/remove) → full reconfigure (same as before)
- Content-only changes → skip reconfigure, let Make handle rebuild (optimization)
