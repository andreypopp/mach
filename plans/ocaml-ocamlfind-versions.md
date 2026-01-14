# Plan: Track OCaml and ocamlfind Versions

## Overview

Track OCaml and ocamlfind versions to detect when toolchain changes require
reconfiguration. This ensures builds use correct compiler settings and prevents
subtle issues from toolchain version mismatches.

## Requirements (from TODO)

1. On startup, detect which ocaml and ocamlfind versions are installed and store
   in config
2. Persist versions in `Mach.state` header
3. On reconfiguration check, detect if versions have changed
4. On reconfiguration, check if ocamlfind is installed when modules reference
   libs

## Implementation

### 1. Add toolchain info type to `lib/mach_config.ml`

Add a new type to represent detected toolchain information:

```ocaml
type toolchain = {
  ocaml_version: string;           (* e.g., "5.2.0" *)
  ocamlfind_version: string option; (* None if not installed *)
}
```

Add a function to detect toolchain versions at startup:

```ocaml
let detect_toolchain () =
  let run_cmd cmd =
    let ic = Unix.open_process_in cmd in
    let output = try Some (input_line ic) with End_of_file -> None in
    match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> output
    | _ -> None
  in
  let ocaml_version =
    match run_cmd "ocamlopt -version" with
    | Some v -> v
    | None -> failwith "ocamlopt not found"
  in
  let ocamlfind_version = run_cmd "ocamlfind query -format '%v' findlib" in
  { ocaml_version; ocamlfind_version }
```

Add `toolchain` field to `Mach_config.t`:

```ocaml
type t = {
  home: string;
  build_backend: build_backend;
  mach_executable_path: string;
  toolchain: toolchain;  (* NEW *)
}
```

Update `make_config` to call `detect_toolchain()` and populate the field.

### 2. Update state header in `lib/mach_state.ml`

Extend the header type to include toolchain info:

```ocaml
type header = {
  build_backend : Mach_config.build_backend;
  mach_executable_path : string;
  ocaml_version : string;              (* NEW *)
  ocamlfind_version : string option;   (* NEW *)
}
```

Update `read` to parse new header fields:

```
build_backend make
mach_executable_path /path/to/mach
ocaml_version 5.2.0
ocamlfind_version 1.9.6   # or "ocamlfind_version none" if not installed

path/to/module.ml 1234567 100
  requires ./dep.ml
  lib cmdliner
```

Update `write` to serialize new header fields.

Update `collect_exn` to populate new header fields from config.

### 3. Update `needs_reconfigure_exn` in `lib/mach_state.ml`

Add checks for toolchain version changes:

```ocaml
let needs_reconfigure_exn config state =
  let toolchain = config.Mach_config.toolchain in
  if state.header.ocaml_version <> toolchain.ocaml_version then
    (Mach_log.log_very_verbose "mach:state: ocaml version changed, need reconfigure"; true)
  else if state.header.ocamlfind_version <> toolchain.ocamlfind_version then
    (Mach_log.log_very_verbose "mach:state: ocamlfind version changed, need reconfigure"; true)
  else
    (* existing checks for build_backend, mach_path, file changes... *)
```

### 4. Check ocamlfind availability when libs are used

In `lib/mach_state.ml`, update `collect_exn` to track `has_libs` during DFS
traversal (avoiding a second O(n) scan), then validate ocamlfind availability:

```ocaml
let collect_exn config entry_path =
  let build_backend = config.Mach_config.build_backend in
  let mach_executable_path = config.Mach_config.mach_executable_path in
  let entry_path = Unix.realpath entry_path in
  let header = { build_backend; mach_executable_path; ... } in
  let visited = Hashtbl.create 16 in
  let entries = ref [] in
  let has_libs = ref false in  (* Track during DFS *)
  let rec dfs ml_path =
    if Hashtbl.mem visited ml_path then ()
    else begin
      Hashtbl.add visited ml_path ();
      let ~requires, ~libs = Mach_module.extract_requires_exn ml_path in
      if libs <> [] then has_libs := true;  (* Update flag during traversal *)
      List.iter dfs requires;
      let mli_path = mli_path_of_ml_if_exists ml_path in
      let mli_stat = Option.map file_stat mli_path in
      entries := { ml_path; mli_path; ml_stat = file_stat ml_path; mli_stat; requires; libs } :: !entries
    end
  in
  dfs entry_path;
  (* Check ocamlfind availability after DFS completes *)
  if !has_libs && config.toolchain.ocamlfind_version = None then
    Mach_error.user_errorf "modules require ocamlfind packages but ocamlfind is not installed";
  match !entries with
  (* ... rest unchanged ... *)
```

### 5. Update `.mli` files

Update `lib/mach_config.mli`:

```ocaml
type toolchain = {
  ocaml_version: string;
  ocamlfind_version: string option;
}

type t = {
  home : string;
  build_backend : build_backend;
  mach_executable_path : string;
  toolchain : toolchain;
}
```

Update `lib/mach_state.mli`:

```ocaml
type header = {
  build_backend : Mach_config.build_backend;
  mach_executable_path : string;
  ocaml_version : string;
  ocamlfind_version : string option;
}
```

## File Changes Summary

| File | Changes |
|------|---------|
| `lib/mach_config.ml` | Add `toolchain` type, `detect_toolchain` function, extend `t` |
| `lib/mach_config.mli` | Add `toolchain` type, extend `t` |
| `lib/mach_state.ml` | Extend `header`, update read/write/collect/needs_reconfigure |
| `lib/mach_state.mli` | Extend `header` type |

## Test Plan

Create `test/test_toolchain_version.t`:

1. **Basic version detection**: Verify state file contains ocaml/ocamlfind
   versions
2. **Reconfigure on version change**: Manually edit state file to have wrong
   version, verify reconfigure triggers (this is tricky to test without mocking;
   may just verify state file format)
3. **Missing ocamlfind error**: Test that using `#require "lib";;` when
   ocamlfind is not installed produces a clear error (hard to test in CI where
   ocamlfind is installed; could mock by modifying PATH)

Practical test approach - verify state file format:

```
$ mach run ./simple.ml
hello
$ grep ocaml_version _mach/build/*__simple.ml/Mach.state
ocaml_version 5.2.0
$ grep ocamlfind_version _mach/build/*__simple.ml/Mach.state
ocamlfind_version 1.9.6
```

## Edge Cases

1. **ocamlfind not installed**: `ocamlfind_version` will be `None`. Scripts
   without lib requirements work fine. Scripts with `#require "lib";;` fail
   with clear error.

2. **Toolchain upgraded**: On next run, version mismatch triggers reconfigure.
   This ensures compiled artifacts are rebuilt with new compiler.

3. **State file migration**: Old state files without version fields will fail
   to parse (returning `None` from `read`), triggering automatic reconfigure.
   This is the desired behavior.

## Backward Compatibility

Old state files without version fields in the header will fail to parse, causing
`Mach_state.read` to return `None`. This triggers a full reconfigure, which is
the correct behavior - we want to rebuild with version tracking.
