# Plan: Refactoring - Getting Rid of objects.args

## Overview

Currently, we generate `objects.args` file for each module that contains a list of `.cmo` files (immediate dependencies + current module). Then for linking, we merge all `objects.args` files using `awk` to produce `all_objects.args`.

The new approach uses Makefile variables instead:
1. Define `MACH_OBJS` variable in the main Makefile (empty initially)
2. Each module's `mach.mk` file appends its `.cmo` to `MACH_OBJS` after including dependencies
3. For linking, generate `all_objects.args` from `$(MACH_OBJS)` content

## Current Implementation Analysis

### How `objects.args` is currently generated

In `configure` function (lines 271-281):
```ocaml
let objects_file = Filename.(build_dir / "objects.args") in
Out_channel.with_open_text objects_file (fun oc ->
  List.iter (fun req_path ->
    let req_name = module_name_of_path req_path |> String.uncapitalize_ascii in
    let req_build_dir = default_build_dir req_path in
    output_line oc Filename.(req_build_dir / req_name ^ ".cmo")
  ) resolved_requires;
  output_line oc Filename.(build_dir / module_name ^ ".cmo")
);
```

### How `objects.args` is used in Makefile rules

In `Makefile.configure_ocaml_module` (line 196):
```ocaml
|> rule objects_args [ml] None  (* objects.args depends on .ml *)
```

In `Makefile.link_ocaml_module` (lines 216-217):
```ocaml
let dep_objects_args = List.map (fun dep -> Filename.(dep.build_dir / "objects.args")) all_deps in
let merge_recipe = Printf.sprintf "awk '!seen[$$0]++' %s > %s" (String.concat " " dep_objects_args) all_objects_args in
```

## New Design

### 1. Changes to `mach.mk` generation

Current `mach.mk` structure:
```makefile
ifndef MODULE_PATH_INCLUDED
MODULE_PATH_INCLUDED := 1

include /path/to/dep1/mach.mk
include /path/to/dep2/mach.mk

# configure rules
module.ml: /source/path.ml
	mach configure /source/path.ml -o /build/dir

includes.args: module.ml
objects.args: module.ml

# compile rules
module.cmo: module.ml includes.args dep1.cmi dep2.cmi
	ocamlc -c -args includes.args -o module.cmo module.ml

module.cmi: module.cmo

endif
```

New `mach.mk` structure (no `objects.args` rule, append to `MACH_OBJS`):
```makefile
ifndef MODULE_PATH_INCLUDED
MODULE_PATH_INCLUDED := 1

include /path/to/dep1/mach.mk
include /path/to/dep2/mach.mk

# Append this module's .cmo to MACH_OBJS after dependencies
MACH_OBJS += /build/dir/module.cmo

# configure rules
module.ml: /source/path.ml
	mach configure /source/path.ml -o /build/dir

includes.args: module.ml

# compile rules
module.cmo: module.ml includes.args dep1.cmi dep2.cmi
	ocamlc -c -args includes.args -o module.cmo module.ml

module.cmi: module.cmo

endif
```

The include guard ensures each module is only added to `MACH_OBJS` once, even if multiple modules depend on it.

### 2. Changes to main Makefile generation

Current main Makefile:
```makefile
include /script/build/dir/mach.mk

.PHONY: all
all: /script/build/dir/a.out

all_objects.args: dep1/objects.args dep2/objects.args script/objects.args
	awk '!seen[$$0]++' dep1/objects.args dep2/objects.args script/objects.args > all_objects.args

/script/build/dir/a.out: all_objects.args dep1.cmo dep2.cmo script.cmo
	ocamlc -o /script/build/dir/a.out -args all_objects.args
```

New main Makefile:
```makefile
MACH_OBJS :=

include /script/build/dir/mach.mk

.PHONY: all
all: /script/build/dir/a.out

all_objects.args: $(MACH_OBJS)
	printf '%s\n' $(MACH_OBJS) > $@

/script/build/dir/a.out: all_objects.args $(MACH_OBJS)
	ocamlc -o /script/build/dir/a.out -args all_objects.args
```

Note: `$(MACH_OBJS)` will be populated transitively by the `include` directive, which processes `mach.mk` files in dependency order due to their nested includes.

### 3. Changes to `configure` subcommand

Remove the generation of `objects.args` file entirely. The `configure` function currently writes:
- `module.ml` (preprocessed source) - keep
- `includes.args` (include paths) - keep
- `objects.args` (object files list) - REMOVE
- `mach.mk` (makefile fragment) - modify to append to `MACH_OBJS`

## Implementation Steps

1. **Modify `Makefile` module**:
   - Add `var : string -> string -> t -> t` function to emit variable assignments
   - Add `var_append : string -> string -> t -> t` function to emit `VAR += value`
   - Remove `objects.args` rule from `configure_ocaml_module`
   - Update `link_ocaml_module` to:
     - Define `MACH_OBJS :=` at the start (before include)
     - Generate `all_objects.args` from `$(MACH_OBJS)`
     - Remove the `awk` merge recipe

2. **Modify `mach_mk` function**:
   - Add `MACH_OBJS += /build/dir/module.cmo` after the includes

3. **Modify `configure` function**:
   - Remove the `objects.args` file generation

4. **Update tests** if needed (check if any tests depend on `objects.args` existence)

## Files to Modify

- `bin/main.ml`:
  - `Makefile` module: add `var`, `var_append`, update `configure_ocaml_module`, `link_ocaml_module`
  - `mach_mk` function: add `MACH_OBJS +=` line
  - `configure` function: remove `objects.args` generation

## Testing

Run `dune test` to ensure all existing tests pass after the refactoring.

## Edge Cases to Consider

1. **Empty dependencies**: A script with no `[%%require]` should still work. `MACH_OBJS` will just contain the single script's `.cmo`.

2. **Diamond dependencies**: If A requires B and C, and both B and C require D, the include guard ensures D's `.cmo` is only added once to `MACH_OBJS`.

3. **Topological order**: Since `mach.mk` includes dependencies before appending self to `MACH_OBJS`, the order will be correct (dependencies before dependents).

## Summary of Changes Made

The refactoring was completed successfully. Here are the specific changes:

### `bin/main.ml` changes:

1. **Makefile module**:
   - Added `Var` and `VarAppend` variants to the `item` type
   - Added `var` and `var_append` functions to emit variable assignments
   - Removed `objects.args` rule from `configure_ocaml_module`
   - Updated `link_ocaml_module` to:
     - Remove `~all_deps` parameter (no longer needed)
     - Generate `all_objects.args` using `printf '%s\n' $(MACH_OBJS)`
     - Use `$(MACH_OBJS)` as dependencies for linking

2. **`mach_mk` function**:
   - Added `MACH_OBJS += <cmo_path>` after the dependency includes

3. **`configure` function**:
   - Removed `objects.args` file generation entirely

4. **`run` function**:
   - Added `MACH_OBJS :=` initialization before the include
   - Updated `link_ocaml_module` call to remove `~all_deps`

### Tests updated:
- `test_shebang.t`: Removed `objects.args` from expected output
- `test_build_dir.t`: Removed `objects.args` from expected output
- `test_build_dir_auto.t`: Removed `objects.args` from expected output (2 places)
- `test_simple.t`: Removed `objects.args` from expected output (2 places)
- `test_verbose.t`: Updated expected output to show `printf` instead of `awk`

All tests pass after the refactoring.
