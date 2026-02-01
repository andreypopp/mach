# PPX Support Implementation Plan

## Overview

Add support for ppx preprocessors in mach scripts and libraries. This allows using OCaml ppx rewriters like `ppx_sexp_conv`, `ppx_deriving`, etc.

## Syntax Design

### For Modules/Scripts

Add `#ppx "..."` directives alongside existing `#require "..."`:

```ocaml
#!/usr/bin/env mach run
#require "ppxlib"
#ppx "ppx_sexp_conv"

type t = { name: string } [@@deriving sexp]
```

### For Libraries (Machlib)

Add `ppx` field to Machlib sexp format:

```sexp
(require
  "ppxlib")
(ppx
  "ppx_sexp_conv")
```

## Implementation Strategy

The core idea is to compile a **standalone ppx driver executable** for each compilation unit that uses ppx. This executable is then passed to `mach pp` via the `--pp` flag during preprocessing.

### PPX Driver Executable

For each compilation unit with ppx requires, we generate a ppx driver:

1. **Source file**: `<build_dir>/mach_ppx_driver.ml`
   ```ocaml
   let () = Ppxlib.Driver.standalone ()
   ```

2. **Compilation**: Link this with all requested ppx libraries:
   ```bash
   ocamlfind ocamlopt -linkpkg -package ppx_sexp_conv -o mach_ppx_driver mach_ppx_driver.ml
   ```

3. **Usage**: Pass to `mach pp` during preprocessing:
   ```bash
   mach pp --pp ./mach_ppx_driver -o module.ml source.ml
   ```

   This integrates with the existing preprocessing pipeline in `mach_ocaml_rules.ml` which already supports the `--pp` flag (used for MLX files).

## Implementation Steps

### Step 1: Extend Directive Parsing (`lib/mach_module.ml`)

**Changes:**

1. Add `ppx` type alongside `require`:
   ```ocaml
   type ppx = Ppx_extlib of extlib with_loc
   ```

2. Update module type to include ppx list:
   ```ocaml
   type t = {
     ...
     requires : require list Lazy.t;
     ppxes : ppx list Lazy.t;    (* NEW *)
   }
   ```

3. Extend `extract_requires_exn` to also extract `#ppx` directives:
   - Parse `#ppx "name"` syntax using `Scanf.sscanf line "#ppx %S%_s"`
   - Resolve ppx package against ocamlfind_libs (same validation as `#require`)
   - Store in separate `ppxes` list

4. Update `preprocess_source` to strip `#ppx` lines (already handles any `#` directive)

### Step 2: Extend Library Format (`lib/mach_library.ml`)

**Changes:**

1. Update `machlib` type:
   ```ocaml
   type machlib =
     | Require of string list [@sexp.list]
     | Ppx of string list [@sexp.list]    (* NEW *)
   [@@deriving sexp]
   ```

2. Update `of_path` to parse both `Require` and `Ppx` stanzas:
   ```ocaml
   let requires = lazy begin
     (* existing require parsing *)
   end in
   let ppxes = lazy begin
     List.concat_map (function
       | Ppx ppx_names -> List.map (resolve_ppx ...) ppx_names
       | _ -> []) machlib
   end in
   ```

3. Add `ppxes` field to `library` type:
   ```ocaml
   type library = {
     ...
     requires : Mach_module.require list Lazy.t;
     ppxes : Mach_module.ppx list Lazy.t;    (* NEW *)
   }
   ```

### Step 3: Extend State Tracking (`lib/mach_state.ml`)

**Changes:**

1. Update `mach_module` record:
   ```ocaml
   type mach_module = {
     ...
     requires : Mach_module.require list;
     ppxes : Mach_module.ppx list;    (* NEW *)
   }
   ```

2. Update `mach_lib` record similarly

3. Update validation to check ppx changes:
   ```ocaml
   if not (equal_ppxes !!(m'.ppxes) !!(m.ppxes))
   then Changed m'
   ```

4. Add `equal_ppxes` helper function

### Step 4: Generate PPX Driver Build Rules (`lib/mach_ocaml_rules.ml`)

**New function:**

```ocaml
let compile_ppx_driver rules cfg ~build_dir ~ppxes =
  if ppxes = [] then None
  else
    let driver_ml = Filename.(build_dir / "mach_ppx_driver.ml") in
    let driver_exe = Filename.(build_dir / "mach_ppx_driver") in
    let ppx_packages = String.concat "," (List.map (fun p -> p.v.name) ppxes) in

    (* Rule to write driver source *)
    Mach_build.Rules.rulef rules ~targets:[|driver_ml|] ~deps:[]
      "echo 'let () = Ppxlib.Driver.standalone ()' > %s" driver_ml;

    (* Rule to compile driver *)
    Mach_build.Rules.rulef rules ~targets:[|driver_exe|] ~deps:[driver_ml]
      "ocamlfind ocamlopt -linkpkg -package %s -o %s %s"
      ppx_packages driver_exe driver_ml;

    Some driver_exe
```

**Update `preprocess_ocaml_module`:**

Extend the existing `pp_flag` logic to include ppx driver:

```ocaml
let preprocess_ocaml_module rules cfg ~build_dir ~path_ml ~path_mli ~kind ~ppx_driver =
  let mach = cfg.Mach_config.mach_executable_path in
  let modname = modname_of path_ml in
  let ml = Filename.(build_dir / modname ^ ".ml") in
  let pp_flag = match kind with Mach_module.ML -> "" | MLX -> " --pp mlx-pp" in
  let ppx_flag = match ppx_driver with None -> "" | Some exe -> " --pp " ^ exe in
  let deps = match ppx_driver with None -> [path_ml] | Some exe -> [path_ml; exe] in
  Mach_build.Rules.rulef rules ~targets:[|ml|] ~deps
    "%s pp%s%s -o %s %s" mach pp_flag ppx_flag ml path_ml;
  ...
```

Note: When both MLX and ppx are used, we need to chain the preprocessors. The `mach pp` command should support multiple `--pp` arguments.

### Step 5: Update Configuration (`lib/mach_lib.ml`)

**Changes to `configure_module`:**

1. Extract ppxes from module:
   ```ocaml
   let ppxes = force m.ppxes in
   ```

2. Generate ppx driver build rules if ppxes is non-empty

3. Pass ppx driver path to `compile_ocaml_module`

**Changes to `configure_library`:**

Similar changes for library configuration.

### Step 6: Handle PPX in Preprocessing

Two aspects:

1. **Directive stripping**: The existing `preprocess_source` already handles any line starting with `#` as a directive, so `#ppx` lines will be stripped automatically. No changes needed.

2. **Multiple `--pp` support**: Update `mach pp` command in `bin/mach.ml` to accept multiple `--pp` arguments. When multiple preprocessors are specified, they should be chained (output of one becomes input to the next). This is needed for MLX + ppx combination.

## File Changes Summary

| File | Changes |
|------|---------|
| `lib/mach_module.ml` | Add `ppx` type, extend `extract_requires_exn`, add `ppxes` field |
| `lib/mach_module.mli` | Expose new `ppx` type and `ppxes` field |
| `lib/mach_library.ml` | Add `Ppx` to machlib type, parse ppx stanzas, add `ppxes` field |
| `lib/mach_library.mli` | Expose `ppxes` field |
| `lib/mach_state.ml` | Add `ppxes` to state types, update validation |
| `lib/mach_state.mli` | Update type signatures |
| `lib/mach_ocaml_rules.ml` | Add `compile_ppx_driver`, update `preprocess_ocaml_module` to pass `--pp` |
| `lib/mach_lib.ml` | Integrate ppx handling in configure |
| `bin/mach.ml` | Update `pp_cmd` to support multiple `--pp` arguments |
| `test/test_ppx.t` | New cram test for ppx support |

## Testing Plan

### Test 1: Basic PPX in Script

Create a script using `ppx_sexp_conv`:

```ocaml
#!/usr/bin/env mach run
#ppx "ppx_sexp_conv"

type point = { x: int; y: int } [@@deriving sexp]

let () =
  let p = { x = 1; y = 2 } in
  print_endline (Sexplib0.Sexp.to_string_hum (sexp_of_point p))
```

### Test 2: PPX in Library

Create a library with Machlib containing ppx:

```sexp
(require "ppxlib")
(ppx "ppx_sexp_conv")
```

### Test 3: Multiple PPXes

Test with multiple ppx packages.

### Test 4: PPX with MLX

Test that ppx works with `.mlx` files (both preprocessors should chain).

## Implementation Order

1. **Phase 1**: Directive parsing (`mach_module.ml`, `mach_library.ml`)
2. **Phase 2**: State tracking (`mach_state.ml`)
3. **Phase 3**: Build rules (`mach_ocaml_rules.ml`, `mach_lib.ml`)
4. **Phase 4**: Testing (`test/test_ppx.t`)

## Edge Cases

1. **Empty ppx list**: No driver generated, no `--pp` flag for ppx
2. **Invalid ppx package**: Fail at configure time with source location (like `#require`)
3. **PPX + MLX**: Chain both preprocessors correctly - `mach pp --pp mlx-pp --pp ./mach_ppx_driver`. Order matters: MLX syntax transformation first, then ppx rewriting.
4. **PPX version mismatch**: Detected via toolchain tracking in state

## Dependencies

The implementation requires:
- `ocamlfind` must be installed for any script using ppx
- Individual ppx packages must be installed via opam

