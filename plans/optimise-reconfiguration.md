# Optimise Reconfiguration: Only Reconfigure Affected Modules

## Overview

Currently, when reconfiguration is needed, mach drops all build directories and reconfigures everything from scratch. This is inefficient when only a subset of modules have changed. The optimization is to:

1. Change `Mach_state.needs_reconfigure_exn` to return a list of modules that need reconfiguration
2. Only drop build directories for affected modules
3. Let Make/Ninja handle rebuilding dependent modules via their existing dependency tracking

## Current Behavior Analysis

### Current Code Flow (`mach_lib.ml:155-177`)

```ocaml
let configure_exn config source_path =
  let state, needs_reconfigure =
    match Mach_state.read state_path with
    | None -> Mach_state.collect_exn config source_path, true
    | Some state when Mach_state.needs_reconfigure_exn config state ->
      Mach_state.collect_exn config source_path, true
    | Some state -> state, false
  in
  if needs_reconfigure then begin
    List.iter (fun entry -> rm_rf (build_dir_of entry.Mach_state.ml_path)) state.entries;
    (* ... regenerate all build files ... *)
  end
```

### Current `needs_reconfigure_exn` (`mach_state.ml:120-149`)

Returns `bool` and checks:
1. Environment changes (build backend, mach path, ocaml version, ocamlfind version) → full reconfigure
2. Per-entry: file removed, .mli added/removed, requires/libs changed → full reconfigure

## Design

### New Return Type

Change from `bool` to a variant that distinguishes between full and partial reconfiguration:

```ocaml
type reconfigure_reason =
  | Env_changed  (* build backend, mach path, toolchain version *)
  | Modules_changed of SS.t  (* set of ml_path that changed *)

val check_reconfigure_exn : Mach_config.t -> t -> reconfigure_reason option
```

When `None` is returned, no reconfiguration is needed.
When `Some Env_changed` is returned, full reconfiguration is needed.
When `Some (Modules_changed paths)` is returned, only those modules need reconfiguration.

### Implementation Details

#### 1. `mach_state.mli` Changes

```ocaml
(** Reason for reconfiguration *)
type reconfigure_reason =
  | Env_changed  (** Build backend, mach path, or toolchain version changed *)
  | Modules_changed of SS.t  (** Set of ml_path that need reconfiguration *)

(** Check if state needs reconfiguration, and if so, what kind *)
val check_reconfigure_exn : Mach_config.t -> t -> reconfigure_reason option
```

Remove `needs_reconfigure_exn` - it's only used internally and `check_reconfigure_exn` replaces it.

#### 2. `mach_state.ml` Implementation

```ocaml
type reconfigure_reason =
  | Env_changed
  | Modules_changed of SS.t

let check_reconfigure_exn config state =
  let build_backend = config.Mach_config.build_backend in
  let mach_path = config.Mach_config.mach_executable_path in
  let toolchain = config.Mach_config.toolchain in
  (* Check environment first - if changed, need full reconfigure *)
  let env_changed =
    state.header.build_backend <> build_backend ||
    state.header.mach_executable_path <> mach_path ||
    state.header.ocaml_version <> toolchain.ocaml_version ||
    (state.header.ocamlfind_version <> None &&
     state.header.ocamlfind_version <> (Lazy.force toolchain.ocamlfind).ocamlfind_version)
  in
  if env_changed then
    (Mach_log.log_very_verbose "mach:state: environment changed, need reconfigure";
     Some Env_changed)
  else
    (* Check each entry for changes *)
    let changed_modules = SS.of_list @@ List.filter_map (fun entry ->
      if not (Sys.file_exists entry.ml_path) then None  (* removed files handled by collect_exn *)
      else if mli_path_of_ml_if_exists entry.ml_path <> entry.mli_path
      then (Mach_log.log_very_verbose "mach:state: .mli added/removed, need reconfigure";
            Some entry.ml_path)
      else if not (equal_file_stat (file_stat entry.ml_path) entry.ml_stat)
      then
        let ~requires, ~libs = Mach_module.extract_requires_exn entry.ml_path in
        if not (List.equal equal_without_loc requires entry.requires) ||
           not (List.equal equal_without_loc libs entry.libs)
        then (Mach_log.log_very_verbose "mach:state: requires/libs changed, need reconfigure";
              Some entry.ml_path)
        else None
      else None
    ) state.entries in
    if SS.is_empty changed_modules then None
    else Some (Modules_changed changed_modules)
```

#### 3. `mach_lib.ml` Changes

The key insight is that when only specific modules change:
- We only need to drop and regenerate their build directories
- The root `Makefile`/`build.ninja` still includes all module build files
- Dependencies handle rebuilds automatically (`.cmo` depends on dependency `.cmi`)

**Update `configure_backend` signature** to accept optional changed modules:

```ocaml
let configure_backend config state ~changed_modules =
  (* ... existing setup code ... *)

  (* Generate per-module build files - only for changed/new modules *)
  List.iter (fun (m : ocaml_module) ->
    let needs_configure = match changed_modules with
      | None -> true  (* full reconfigure *)
      | Some set -> SS.mem m.ml_path set || not (Sys.file_exists m.build_dir)
    in
    if needs_configure then begin
      mkdir_p m.build_dir;
      let file_path = Filename.(m.build_dir / module_file) in
      write_file file_path (
        let b = B.create () in
        configure_ocaml_module b m;
        compile_ocaml_module b m;
        B.contents b)
    end
  ) modules;

  (* Always regenerate root build file - module list may have changed *)
  (* ... existing root build file generation ... *)
```

**Update `configure_exn`:**

```ocaml
let configure_exn config source_path =
  let build_dir_of = Mach_config.build_dir_of config in
  let source_path = Unix.realpath source_path in
  let build_dir = build_dir_of source_path in
  let state_path = Filename.(build_dir / "Mach.state") in
  let state, reconfigure_reason =
    match Mach_state.read state_path with
    | None ->
      log_very_verbose "mach:configure: no previous state found, creating one...";
      Mach_state.collect_exn config source_path, Some Mach_state.Env_changed
    | Some state ->
      match Mach_state.check_reconfigure_exn config state with
      | None -> state, None
      | Some reason ->
        log_very_verbose "mach:configure: need reconfigure";
        Mach_state.collect_exn config source_path, Some reason
  in
  let reconfigured = reconfigure_reason <> None in
  if reconfigured then begin
    log_verbose "mach: configuring...";
    let changed_modules = match reconfigure_reason with
      | Some Env_changed | None -> None  (* full reconfigure *)
      | Some (Modules_changed set) -> Some set
    in
    (* Drop build dirs for changed modules *)
    (match changed_modules with
    | None ->
      List.iter (fun entry -> rm_rf (build_dir_of entry.Mach_state.ml_path)) state.entries
    | Some set ->
      List.iter (fun entry ->
        if SS.mem entry.Mach_state.ml_path set then
          rm_rf (build_dir_of entry.ml_path)
      ) state.entries);
    mkdir_p build_dir;
    configure_backend config state ~changed_modules;
    Mach_state.write state_path state
  end;
  ~state, ~reconfigured
```

## Edge Cases

### 1. New Module Added to Dependency Graph

When a module adds a new `#require`:
- The changed module is in `Modules_changed`
- The new dependency is collected by `Mach_state.collect_exn`
- Its build dir doesn't exist yet, so it gets created by `configure_backend`
- The root build file is regenerated and includes the new module

### 2. Module Removed from Dependency Graph

When a module removes a `#require`:
- The changed module is in `Modules_changed`
- The removed dependency is NOT in the new state's entries
- Its stale build dir remains but is harmless (not included in root build file)

### 3. Transitive Changes

If A requires B, and B's requires change:
- B is in `Modules_changed`
- B's build dir is dropped and regenerated
- A's build dir remains
- Make/Ninja rebuilds A because B's `.cmi` changed

## Testing Strategy

### New Test: `test_partial_reconfigure.t`

```
Test partial reconfiguration - only affected modules are reconfigured.

  $ . ../env.sh

Create a script with two dependencies:

  $ cat << 'EOF' > lib_a.ml
  > let msg = "lib_a"
  > EOF

  $ cat << 'EOF' > lib_b.ml
  > let msg = "lib_b"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib_a"
  > #require "./lib_b"
  > let () = Printf.printf "%s %s\n" Lib_a.msg Lib_b.msg
  > EOF

First build:

  $ mach run ./main.ml
  lib_a lib_b

Check build dirs exist:

  $ ls $MACH_HOME/_mach/build/ | sort
  [various normalized paths for lib_a, lib_b, main]

Change only lib_a's requires (add new require):

  $ cat << 'EOF' > lib_c.ml
  > let extra = "!"
  > EOF

  $ sleep 1
  $ cat << 'EOF' > lib_a.ml
  > #require "./lib_c"
  > let msg = "lib_a" ^ Lib_c.extra
  > EOF

  $ mach run -vv ./main.ml 2>&1 | grep -E "(reconfigure|configuring)"
  mach:state: requires/libs changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...

  $ mach run ./main.ml
  lib_a! lib_b
```

### Existing Tests to Verify

The existing tests in `test/` should continue to pass:
- `test_reconfigure.t` - verifies reconfiguration triggers
- `test_dep_add.t` - adding dependencies
- `test_dep_remove.t` - removing dependencies
- `test_dep_transitive_add.t` - transitive dependency changes
- `test_dep_transitive_remove.t` - transitive dependency removal

## Implementation Steps

1. Add `reconfigure_reason` type to `mach_state.mli`
2. Replace `needs_reconfigure_exn` with `check_reconfigure_exn` in `mach_state.mli`
3. Implement `reconfigure_reason` type in `mach_state.ml`
4. Replace `needs_reconfigure_exn` with `check_reconfigure_exn` in `mach_state.ml`
5. Update `configure_backend` in `mach_lib.ml` to accept `~changed_modules` parameter
6. Update `configure_exn` in `mach_lib.ml` to use partial reconfiguration
7. Add `test_partial_reconfigure.t` test
8. Run `dune test` to verify all tests pass

## Summary

This optimization reduces unnecessary work during reconfiguration by:
- Only dropping build directories for modules whose structure changed
- Letting Make/Ninja handle rebuilds of dependent modules via existing `.cmi` dependencies
- Preserving unchanged module build artifacts for faster incremental builds
