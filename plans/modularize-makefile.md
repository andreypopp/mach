# Plan: Modularize Makefile

## Overview

Refactor the Makefile generation to produce modular `mach.mk` files for each OCaml module instead of a single monolithic Makefile.

## Current Architecture

Currently (`bin/main.ml:281-294`), a single `Makefile` is generated in the script's build directory containing:
- Configuration rules for all modules (script + dependencies)
- Compilation rules for all modules
- Linking rule for the final executable

Each module has its own build directory (`~/.config/mach/build/<normalized-path>/`) containing:
- `<module>.ml` - preprocessed source
- `<module>.cmo` / `<module>.cmi` - compiled artifacts
- `includes.args` - `-I` flags for immediate dependencies
- `objects.args` - `.cmo` paths for immediate dependencies + self

## Target Architecture

### Per-module `mach.mk` files

Each module's build directory will contain a `mach.mk` file with:

1. **Include directives** for immediate dependencies' `mach.mk` files
2. **Configure target** - generates preprocessed `.ml`, `includes.args`, `objects.args`
3. **Compile target** - produces `.cmo` and `.cmi`

Example structure for `lib_a.ml` which depends on `lib_b.ml`:

```makefile
# mach.mk for lib_a

# Include dependencies' makefiles
include /path/to/lib_b/mach.mk

# Configuration target
/path/to/lib_a/lib_a.ml: /absolute/path/to/lib_a.ml
	mach configure /absolute/path/to/lib_a.ml -o /path/to/lib_a

/path/to/lib_a/includes.args: /path/to/lib_a/lib_a.ml

/path/to/lib_a/objects.args: /path/to/lib_a/lib_a.ml

# Compilation target
/path/to/lib_a/lib_a.cmo: /path/to/lib_a/lib_a.ml /path/to/lib_a/includes.args /path/to/lib_b/lib_b.cmi
	ocamlc -c -args /path/to/lib_a/includes.args -o /path/to/lib_a/lib_a.cmo /path/to/lib_a/lib_a.ml

/path/to/lib_a/lib_a.cmi: /path/to/lib_a/lib_a.cmo
```

### Root `Makefile`

The script's build directory will contain a `Makefile` that:

1. **Includes** the script's own `mach.mk`
2. **Generates `all_objects.args`** - merges all `objects.args` files with deduplication
3. **Links the final executable**

```makefile
# Makefile for script

include /path/to/main/mach.mk

.PHONY: all

all: /path/to/main/a.out

/path/to/main/all_objects.args: /path/to/lib_b/objects.args /path/to/lib_a/objects.args /path/to/main/objects.args
	awk '!seen[$$0]++' /path/to/lib_b/objects.args /path/to/lib_a/objects.args /path/to/main/objects.args > /path/to/main/all_objects.args

/path/to/main/a.out: /path/to/main/all_objects.args /path/to/lib_b/lib_b.cmo /path/to/lib_a/lib_a.cmo /path/to/main/main.cmo
	ocamlc -o /path/to/main/a.out -args /path/to/main/all_objects.args
```

## Implementation Steps

### Step 1: Modify `configure` subcommand

The `configure` subcommand already produces most of what we need. We need to extend it to also generate the `mach.mk` file.

Add logic to `configure` (`bin/main.ml:223-255`) to:
- Generate `mach.mk` with include directives for dependencies
- Add configure rule (already exists in monolithic Makefile)
- Add compile rule (already exists in monolithic Makefile)

### Step 2: Refactor `Makefile` module

Modify the `Makefile` module to support:
- **New function `mach_mk_for_module`**: generates content for a single module's `mach.mk`
- **Modify `contents`**: add support for include directives at the top
- Keep existing `configure_ocaml_module`, `compile_ocaml_module` (they'll be used for `mach.mk` generation)

Add new signature:
```ocaml
val mach_mk : ocaml_module -> string
(* Generates mach.mk content for a module *)
```

### Step 3: Modify `run` subcommand

Update the `run` function (`bin/main.ml:259-305`) to:
1. For each dependency, call `configure` which now also generates `mach.mk`
2. Generate root `Makefile` that:
   - Includes script's `mach.mk` (which transitively includes all dependencies)
   - Has the linking rules

### Step 4: Handle include ordering

Makefile includes are processed in order. Since each `mach.mk` includes its dependencies first (via `include` directives), the dependency order is naturally preserved through the include chain.

**Key insight**: The include chain forms a DAG that mirrors the dependency graph:
- `main/mach.mk` includes `lib_a/mach.mk`
- `lib_a/mach.mk` includes `lib_b/mach.mk`
- When Make processes `main/Makefile`, it first processes `lib_b`, then `lib_a`, then `main`

### Step 5: Handle duplicate includes

GNU Make handles duplicate includes gracefully - if a file is included multiple times, it's only processed once. This handles the diamond dependency case automatically.

For example, if both `a.ml` and `b.ml` depend on `lib.ml`:
- `a/mach.mk` includes `lib/mach.mk`
- `b/mach.mk` includes `lib/mach.mk`
- `main/mach.mk` includes both `a/mach.mk` and `b/mach.mk`
- Make will only process `lib/mach.mk` once

## Code Changes Summary

1. **`Makefile` module** (`bin/main.ml:152-219`):
   - Add `include_` function to add include directives
   - Add `mach_mk : ocaml_module -> string` function
   - Modify `contents` to output includes before rules

2. **`configure` function** (`bin/main.ml:223-255`):
   - After writing `includes.args` and `objects.args`, also write `mach.mk`

3. **`run` function** (`bin/main.ml:259-305`):
   - Replace monolithic Makefile generation with:
     - For each dep: configure (now generates `mach.mk`)
     - Generate root `Makefile` with: include script's `mach.mk`, linking rules

## Testing

Existing tests should continue to pass since the external behavior doesn't change. The generated Makefile structure is different but the build result is the same.

Additional test considerations:
- `test_verbose.t` may need updating if make output changes
- `test_build_dir.t` may need updating to show `mach.mk` in the file list

## Benefits of This Refactoring

1. **Modularity**: Each module's build rules are self-contained
2. **Caching efficiency**: When a module is already configured, its `mach.mk` can be reused
3. **Incremental builds**: Changes to one module don't require regenerating rules for others
4. **Future extensibility**: Makes it easier to add remote requires - each remote dependency can have its own `mach.mk`

---

## Implementation Summary

### Changes Made

1. **`Makefile` module** (`bin/main.ml`):
   - Added `Include` variant to the internal `item` type
   - Added `include_` function to add include directives
   - Added `mach_mk` function that generates a complete `mach.mk` file with:
     - Include guards (using `ifndef`/`endif`) to prevent duplicate rule warnings
     - Include directives for dependencies' `mach.mk` files
     - Configure and compile rules for the module

2. **`configure` function** (`bin/main.ml`):
   - Now also generates `mach.mk` file alongside existing outputs

3. **`run` function** (`bin/main.ml`):
   - Added `write_mach_mk` helper to eagerly generate `mach.mk` files
   - Generates `mach.mk` for all modules before writing the root Makefile
   - Root Makefile now includes script's `mach.mk` (which transitively includes all dependencies)
   - Root Makefile only contains linking rules (configure/compile rules come from included `mach.mk` files)

4. **Tests updated**:
   - Added `mach.mk` to expected file listings in affected tests

### Key Implementation Detail

Include guards were necessary to handle diamond dependencies (e.g., both `a.ml` and `b.ml` depend on `lib.ml`). Without guards, Make would warn about duplicate rule definitions when `lib/mach.mk` gets included through multiple paths.
