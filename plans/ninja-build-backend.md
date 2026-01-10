# Plan: Implement Ninja Build Backend

## Overview

This plan implements a ninja build backend for mach, alongside the existing Make backend. The work involves refactoring the current `Makefile` module to separate OCaml-specific logic, then creating a new `Ninja` module that shares the same interface.

## Current State Analysis

The `Makefile` module in `lib/mach_lib.ml` (lines 176-247) currently mixes two concerns:
1. **Makefile syntax generation** - `var`, `var_append`, `include_`, `rule'`, `rule''`, `rule`
2. **OCaml compilation logic** - `configure_ocaml_module`, `compile_ocaml_module`, `link_ocaml_module`, `includes_args`

The OCaml-specific functions encode knowledge about:
- File extensions (`.ml`, `.mli`, `.cmo`, `.cmi`, `.cmt`, `.cmti`)
- `ocamlc` command line arguments
- Dependencies between compilation artifacts
- The `includes.args` and `all_objects.args` file conventions

## Implementation Steps

### Step 1: Extract OCaml-specific Functions from Makefile Module

First, extract the OCaml-specific functions (`configure_ocaml_module`, `compile_ocaml_module`, `link_ocaml_module`, `includes_args`) out of the `Makefile` module as standalone functions in `mach_lib.ml`.

These functions will receive:
1. A first-class module of `BUILD` type
2. A `BUILD.t` value

This separates:
- **What to build** (OCaml modules, their dependencies, compiler flags)
- **How to express it** (Make syntax vs Ninja syntax)

### Step 2: Create `lib/s.ml` with BUILD Module Type

Create a new file `lib/s.ml` (s for signatures) containing the `BUILD` module type:

**lib/s.ml:**
```ocaml
module type BUILD = sig
  type t
  val create : unit -> t
  val contents : t -> string

  val var : t -> string -> string -> unit
  val var_append : t -> string -> string -> unit
  val include_ : t -> string -> unit
  val rule : t -> target:string -> deps:string list -> recipe:string list -> unit
  val rule_phony : t -> target:string -> deps:string list -> unit
end
```

This avoids circular dependencies: `makefile.ml` and `ninja.ml` can depend on `S.BUILD`, and `mach_lib.ml` can also depend on it.

### Step 3: Create Standalone OCaml Build Functions

Extract OCaml-specific logic as functions that take a first-class module:

```ocaml
let configure_ocaml_module (type a) (module B : S.BUILD with type t = a) (buf : a) (m : ocaml_module) =
  let ml = Filename.(m.build_dir / m.module_name ^ ".ml") in
  let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
  let preprocess_deps = m.ml_path :: Option.to_list m.mli_path in
  B.rule buf ~target:ml ~deps:preprocess_deps
    ~recipe:[sprintf "mach preprocess %s -o %s" m.ml_path m.build_dir];
  if Option.is_some m.mli_path then
    B.rule buf ~target:mli ~deps:[ml] ~recipe:[];
  includes_args (module B) buf m

let compile_ocaml_module (type a) (module B : BUILD with type t = a) (buf : a) (m : ocaml_module) =
  (* ... similar pattern ... *)

let link_ocaml_module (type a) (module B : BUILD with type t = a) (buf : a) (m : ocaml_module) ~exe_path =
  (* ... similar pattern ... *)
```

### Step 4: Create `lib/makefile.ml` and `lib/makefile.mli`

Move the Makefile syntax generation to its own file:

**lib/makefile.mli:**
```ocaml
include S.BUILD
```

**lib/makefile.ml:**
```ocaml
type t = Buffer.t
let create () = Buffer.create 1024
let contents = Buffer.contents
let var buf name value = Printf.bprintf buf "%s := %s\n" name value
let var_append buf name value = Printf.bprintf buf "%s += %s\n" name value
let include_ buf path = Printf.bprintf buf "include %s\n" path

let rule buf ~target ~deps ~recipe =
  Printf.bprintf buf "%s:" target;
  List.iter (Printf.bprintf buf " %s") deps;
  Buffer.add_char buf '\n';
  List.iter (Printf.bprintf buf "\t%s\n") recipe;
  Buffer.add_char buf '\n'

let rule_phony buf ~target ~deps =
  Printf.bprintf buf ".PHONY: %s\n" target;
  rule buf ~target ~deps ~recipe:[]
```

### Step 5: Create `lib/ninja.ml` and `lib/ninja.mli`

Implement the same interface for Ninja:

**lib/ninja.mli:**
```ocaml
include S.BUILD
```

**lib/ninja.ml:**

Ninja syntax differences:
- Variables: `name = value` (not `:=`)
- Rules: Define a rule template, then use `build target: rule_name deps`
- No direct variable append (need different approach)
- `include path` for includes (similar)
- `phony` is a built-in rule

Key challenge: Ninja requires rules to be defined before use. For generic `rule` function, we can use the built-in `command` approach:

```ninja
rule cmd
  command = $cmd

build target: cmd dep1 dep2
  cmd = actual command here
```

Or we can emit inline shell commands. The simplest approach for compatibility:

```ocaml
type t = Buffer.t

let create () =
  let buf = Buffer.create 1024 in
  (* Define a generic command rule at the top *)
  Printf.bprintf buf "rule cmd\n  command = $cmd\n\n";
  buf

let rule buf ~target ~deps ~recipe =
  Printf.bprintf buf "build %s:" target;
  match recipe with
  | [] ->
    Printf.bprintf buf " phony";
    List.iter (Printf.bprintf buf " %s") deps;
    Buffer.add_char buf '\n'
  | _ ->
    Printf.bprintf buf " cmd";
    List.iter (Printf.bprintf buf " %s") deps;
    Buffer.add_char buf '\n';
    Printf.bprintf buf "  cmd = %s\n" (String.concat " && " recipe)

let rule_phony buf ~target ~deps =
  Printf.bprintf buf "build %s: phony" target;
  List.iter (Printf.bprintf buf " %s") deps;
  Buffer.add_char buf '\n'

let var buf name value = Printf.bprintf buf "%s = %s\n" name value
let var_append _ _ _ = () (* No-op for ninja, handle differently *)
let include_ buf path = Printf.bprintf buf "include %s\n" path
```

**Note on `var_append`:** Since Ninja doesn't support variable appending and it's only used for `MACH_OBJS`, we have two options:
- A) Make it a no-op in Ninja and generate `all_objects.args` directly during configure
- B) Track appended values in a ref and emit at `contents` time

**Recommended: Option A** - Generate `all_objects.args` directly at configure time since we know all modules then. This simplifies both backends.

We do A. option

### Step 6: Refactor `configure` to Use Build Backend

The `configure` function needs to:
1. Accept a build backend as a first-class module
2. Pass it to the OCaml build functions
3. Generate either `Makefile`/`mach.mk` or `build.ninja`/`mach.ninja`

```ocaml
let configure (type a) (module B : S.BUILD with type t = a) source_path =
  (* ... existing logic ... *)
  let mk = B.create () in
  configure_ocaml_module (module B) mk m;
  compile_ocaml_module (module B) mk m;
  (* ... *)
```

### Step 7: Add `--build-backend` CLI Option

**bin/mach.ml changes:**

```ocaml
type build_backend = Make | Ninja

let build_backend_arg =
  let doc = "Build backend to use: 'make' (default) or 'ninja'" in
  let parser = function
    | "make" -> Ok Make
    | "ninja" -> Ok Ninja
    | s -> Error (`Msg (Printf.sprintf "Unknown build backend: %s" s))
  in
  let printer fmt = function
    | Make -> Format.pp_print_string fmt "make"
    | Ninja -> Format.pp_print_string fmt "ninja"
  in
  let conv = Arg.conv (parser, printer) in
  Arg.(value & opt conv Make & info ["build-backend"] ~doc)
```

Add to `run`, `build`, and `configure` commands.

### Step 8: Update `build` Function

The `build` function needs to dispatch to the correct build tool:

```ocaml
let build verbose backend script_path =
  let module B = (val match backend with Make -> (module Makefile : S.BUILD) | Ninja -> (module Ninja : S.BUILD)) in
  let _state, root_module, exe_path = configure (module B) script_path in
  let cmd = match backend with
    | Make -> if verbose then "make all" else "make -s all"
    | Ninja -> if verbose then "ninja -v" else "ninja"
  in
  let cmd = sprintf "%s -C %s" cmd (Filename.quote root_module.build_dir) in
  if verbose then eprintf "+ %s\n%!" cmd;
  commandf "%s" cmd;
  exe_path
```

### Step 9: Update lib/dune

Add the new modules:

```dune
(library
 (name mach_lib)
 (libraries unix))
```

The `BUILD` module type lives in `lib/s.ml`, so `Makefile` and `Ninja` modules can implement `S.BUILD` without circular dependencies.

## File Changes Summary

### New Files

1. `lib/s.ml` - Module signatures (contains `BUILD` module type)
2. `lib/makefile.mli` - Makefile backend interface
3. `lib/makefile.ml` - Makefile backend implementation
4. `lib/ninja.mli` - Ninja backend interface
5. `lib/ninja.ml` - Ninja backend implementation

### Modified Files

1. `lib/mach_lib.ml`:
   - Remove `Makefile` module (moved to `lib/makefile.ml`)
   - Add standalone OCaml build functions taking first-class modules of type `S.BUILD`
   - Update `configure` to accept backend parameter
   - Update `build` to dispatch to correct tool

2. `lib/dune`:
   - No changes needed if modules auto-discovered, otherwise add `makefile` and `ninja`

3. `bin/mach.ml`:
   - Add `--build-backend` argument
   - Thread backend through `run`, `build`, `configure` commands

### New Test Files

1. `test/test_ninja.t` - Test ninja backend functionality

## Ninja-specific Considerations

1. **Rule definitions**: Ninja requires explicit rule definitions. Using a generic `cmd` rule with `$cmd` variable allows flexibility.

2. **Order-only dependencies**: Ninja uses `| dep` for order-only deps (implicit deps that don't trigger rebuilds). May be useful for `includes.args`.

3. **File naming**:
   - Root: `build.ninja` (standard Ninja convention)
   - Per-module: `mach.ninja` (parallel to `mach.mk`)

4. **Include syntax**: Same as Make - `include path`

5. **Subninja**: Alternative to `include` that scopes variables. May not be needed.

## Execution Order

1. Create `lib/s.ml` with `BUILD` module type
2. Create `lib/makefile.ml` and `lib/makefile.mli` with generic Makefile generation (implementing `S.BUILD`)
3. Extract OCaml-specific functions from `Makefile` module in `mach_lib.ml`, make them take first-class `S.BUILD` module
4. Update `mach_lib.ml` to use first-class module pattern for `configure` and `build`
5. Verify all existing tests pass
6. Create `lib/ninja.ml` and `lib/ninja.mli` (implementing `S.BUILD`)
7. Add `--build-backend` CLI option
8. Add `test/test_ninja.t`
9. Verify all tests pass

## Risk Assessment

1. **Low risk**: Extracting functions - pure refactoring, no behavior change
2. **Medium risk**: First-class module pattern - need to get types right
3. **Medium risk**: Ninja syntax correctness - needs careful testing
4. **Low risk**: CLI changes - straightforward cmdliner additions

## Testing Strategy

1. All existing cram tests should continue to pass (they use default Make backend)
2. Add `test/test_ninja.t` that:
   - Runs same scenarios with `--build-backend ninja`
   - Verifies `build.ninja` files are generated
   - Verifies compilation works correctly
