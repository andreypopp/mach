# Plan: Port from Ninja to Mach_build

## Overview

Currently mach uses Ninja as its build backend. The codebase generates `mach.ninja` files via the `Ninja` module and invokes `ninja` to build. We want to replace this with `Mach_build`, a pure OCaml build system that's already implemented and tested (see `test_builder.t` and `test_builder_dyndep.t`).

## Current Architecture

### Ninja Module (lib/ninja.ml)
The `Ninja` module provides a simple API for generating Ninja build files:
- `create()` - creates a buffer with a `rule cmd` definition
- `var buf name value` - adds a variable definition
- `subninja buf path` - includes another ninja file
- `rule buf ~target ~deps ?order_only_deps ?dyndep recipe` - generates a build rule
- `rulef` - printf-style version of `rule`
- `rule_phony` - generates a phony target

### Mach_build Module (lib/mach_build.ml)
Already implemented with:
- `Build_file_format` - sexp-based format for build rules (`Rule`, `Rule_dyndep`)
- `Dyndep_file_format` - sexp-based format for dynamic dependencies
- `create()`, `configure()`, `build()` - build system implementation
- Supports dynamic dependencies (dyndeps) for library module ordering

### Current Usage in mach_lib.ml

1. **Per-module configuration** (`configure_module`, `configure_library`):
   - Creates a `Ninja.t` buffer
   - Calls functions in `Mach_ocaml_rules` to generate rules
   - Writes buffer to `mach.ninja`

2. **Root configuration** (`configure_exn`):
   - Creates root `build.ninja` with:
     - `subninja` directives for all module/library ninja files
     - Link rule for final executable or library target
     - Phony "all" target

3. **Build execution** (`build_exn`):
   - Runs `ninja -C <build_dir>` to execute the build

## Migration Strategy

### Phase 1: Add Convenience Functions to Mach_build

Add functions to `Mach_build` that mirror the `Ninja` API but produce `Build_file_format.stanza list`:

```ocaml
module Rules : sig
  type t
  val create : unit -> t
  val add : t -> Build_file_format.stanza -> unit
  val to_list : t -> Build_file_format.stanza list

  (* Convenience functions matching Ninja API *)
  val rule : t -> target:string -> deps:string list -> string list -> unit
  val rulef : t -> target:string -> deps:string list -> ('a, unit, string, unit) format4 -> 'a
  val rule_dyndep : t -> target:string -> deps:string list -> string list -> unit
end
```

### Phase 2: Update Mach_ocaml_rules

Replace `Ninja.t` with `Mach_build.Rules.t` in all functions:
- `preprocess_ocaml_module`
- `compile_ocaml_args`
- `compile_ocaml_module`
- `link_ocaml_executable`
- `link_ocaml_library`

The function signatures change from taking `Ninja.t` to taking `Mach_build.Rules.t`, but the logic remains the same.

### Phase 3: Update mach_lib.ml

1. **configure_module/configure_library**:
   - Replace `Ninja.create()` with `Mach_build.Rules.create()`
   - Write `mach.build` (sexp format) instead of `mach.ninja`

2. **configure_exn** (root configuration):
   - Instead of generating `build.ninja` with `subninja` directives:
     - Load all `mach.build` files
     - Merge them into a single `Build_file_format.t`
     - Add link rules for executable/library
     - Write combined `build.build` file
   - Remove `ninja cleandead` call (not needed with Mach_build)

3. **build_exn**:
   - Replace `ninja -C <dir>` with:
     - Load `build.build`
     - Call `Mach_build.configure` and `Mach_build.build`

### Phase 4: Handle Variables

The current code uses Ninja variables like `$MACH` and `${MACH}`. Since Mach_build uses shell commands directly:
- Replace variable references with actual values in command strings
- Pass the mach executable path through the rule-generating functions

### Phase 5: Update `mach dep` and `mach link-deps` Subcommands

#### `mach dep`

The `mach dep` command runs ocamldep and outputs dyndep files. Currently it outputs **ninja dyndep format**:

```
ninja_dyndep_version = 1
build foo.cmx: dyndep | bar.cmx baz.cmx
```

It must be updated to output **Mach_build.Dyndep_file_format** (sexp):

```
((target "/path/to/foo.cmx") (deps ("/path/to/bar.cmx" "/path/to/baz.cmx")))
```

Changes to `bin/mach.ml` `dep_cmd`:
- Remove `ninja_dyndep_version = 1` header
- Change output format from `build X: dyndep | Y Z` to sexp `((target "X") (deps ("Y" "Z")))`
- Can use `Mach_build.Dyndep_file_format.to_file` for correct serialization

#### `mach link-deps`

The `mach link-deps` command reads `.dep` files and outputs topologically sorted `.cmx` files for linking. Currently it parses ninja dyndep format:

```ocaml
(* Format: "build foo.cmx: dyndep | bar.cmx baz.cmx" or "build foo.cmx: dyndep" *)
```

It must be updated to parse the new sexp format using `Mach_build.Dyndep_file_format.of_file`.

Changes to `bin/mach.ml` `link_deps_cmd`:
- Replace custom `parse_dep_file` with `Mach_build.Dyndep_file_format.of_file`
- Build dependency graph from parsed `dyndep` records
- Rest of topological sort logic remains the same

### Phase 6: Clean Up

1. Remove the `ninja.ml` and `ninja.mli` files
2. Update tests that check for `mach.ninja` files
3. Remove any ninja-specific code (cleandead, verbose ninja output)

## File Changes Summary

| File | Changes |
|------|---------|
| `lib/mach_build.ml` | Add `Rules` module with convenience functions |
| `lib/mach_build.mli` | Add interface for `Rules` module |
| `lib/mach_ocaml_rules.ml` | Change parameter type from `Ninja.t` to `Mach_build.Rules.t` |
| `lib/mach_lib.ml` | Replace Ninja usage with Mach_build; change build invocation |
| `lib/ninja.ml` | Delete |
| `lib/ninja.mli` | Delete |
| `lib/dune` | Remove ninja module from build |
| `bin/mach.ml` | Update `dep` and `link-deps` commands for sexp dyndep format; remove ninja verbose handling |
| `test/*.t` | Update tests that check for ninja files |

## Key Differences

1. **File format**: `mach.ninja` (Ninja DSL) → `mach.build` (S-expressions)
2. **Build execution**: External `ninja` process → In-process `Mach_build.build`
3. **Subninja handling**: Ninja's `subninja` → Load and merge all `.build` files
4. **Variables**: `$VAR` substitution → Direct values in commands
5. **Order-only deps**: Ninja's `||` syntax → Not needed (deps are deps)
6. **Phony targets**: Ninja's `phony` rule → Not needed (just use the target path)

## Testing Strategy

1. Run existing test suite after each phase
2. The existing `test_builder.t` and `test_builder_dyndep.t` validate Mach_build works
3. All other tests validate the full mach workflow continues working

## Notes

- Mach_build processes builds sequentially (no parallelism) - acceptable for mach's use case
- The sexp format is more readable and debuggable than ninja format
