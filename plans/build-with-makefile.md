# Plan: Build with Makefile

## Status: COMPLETED

## Overview

Change the build system to generate a single `Makefile` in the script's build directory instead of directly invoking `ocamlc` commands. The Makefile will orchestrate the compilation of all dependencies and the main script, while preserving the existing layout where each module is built in its own build directory.

## Current Implementation

Currently (`bin/main.ml`):
1. `resolve_deps` collects all dependencies via DFS and returns them in topological order
2. For each dependency, the code:
   - Ensures its build directory exists
   - Writes `includes.args` with `-I` paths to dependency build directories
   - Writes preprocessed source to `<module>.ml`
   - Calls `ocamlc -c -args includes.args -o <module>.cmo <module>.ml`
3. For the entry script, same process
4. Writes `objects.args` with all `.cmo` paths
5. Links with `ocamlc -o a.out -args objects.args`
6. Executes the binary

## Proposed Changes

### 1. Replace direct `ocamlc` calls with Makefile generation

Instead of calling `compile` and `link` functions that invoke `ocamlc` directly, we will:
1. Generate a single `Makefile` in the script's build directory
2. Run `make` to build
3. Execute the resulting binary

### 2. Makefile Structure

The generated Makefile will:
- Have the executable (`a.out`) as the default target
- Have targets for each `.cmo` file (dependencies + script)
- Use absolute paths for all build directories
- Use the same `-args` files approach for include paths

Example for a script with two dependencies (`lib_b.ml` depends on nothing, `lib_a.ml` depends on `lib_b.ml`, `main.ml` depends on `lib_a.ml`):

```makefile
.PHONY: all
all: /path/to/main/build/a.out

# Dependency: lib_b (produces both .cmo and .cmi)
/path/to/lib_b/build/lib_b.cmo /path/to/lib_b/build/lib_b.cmi &: /path/to/lib_b/build/lib_b.ml
	ocamlc -c -args /path/to/lib_b/build/includes.args -o /path/to/lib_b/build/lib_b.cmo $<

# Dependency: lib_a (depends on lib_b's .cmi for type info)
/path/to/lib_a/build/lib_a.cmo /path/to/lib_a/build/lib_a.cmi &: /path/to/lib_a/build/lib_a.ml /path/to/lib_b/build/lib_b.cmi
	ocamlc -c -args /path/to/lib_a/build/includes.args -o /path/to/lib_a/build/lib_a.cmo $<

# Main script
/path/to/main/build/main.cmo /path/to/main/build/main.cmi &: /path/to/main/build/main.ml /path/to/lib_a/build/lib_a.cmi
	ocamlc -c -args /path/to/main/build/includes.args -o /path/to/main/build/main.cmo $<

# Link (needs .cmo files)
/path/to/main/build/a.out: /path/to/lib_b/build/lib_b.cmo /path/to/lib_a/build/lib_a.cmo /path/to/main/build/main.cmo
	ocamlc -o $@ -args /path/to/main/build/objects.args
```

Key points:
- Each compilation rule produces both `.cmo` and `.cmi` (using `&:` grouped target syntax, GNU Make 4.3+)
- Each grouped target depends on:
  1. Its `.ml` source file
  2. The `.cmi` files of all its direct dependencies (the same modules referenced in `includes.args`)
- Linking depends on `.cmo` files
- The `includes.args` files are still used for `-I` flags (to tell ocamlc where to find `.cmi` files)
- The `objects.args` file is still used for linking
- Make will handle incremental rebuilds and parallelism

### 3. Code Changes in `bin/main.ml`

#### Remove
- `run_command` function (no longer needed, replaced by `make`)
- `compile` function
- `link` function

#### Add
- `generate_makefile` function that creates the Makefile content
- `write_makefile` function to write it to disk

#### Modify
- `run` function to:
  1. Still do all preprocessing and write source files / args files
  2. Instead of compile/link calls, generate and write Makefile
  3. Run `make` (or `make -j` for parallelism)
  4. Execute the resulting binary

### 4. Verbose Mode

For `--verbose` mode:
- Run `make` without `-s` (silent) flag to show commands
- Or run with `make V=1` or similar

### 5. Implementation Steps

1. **Preparation**: Ensure all source files and args files are written before Makefile generation
2. **Generate Makefile**: Create function to build Makefile content from `deps` list and `entry_parsed`
3. **Write Makefile**: Write to `build_dir/Makefile`
4. **Run Make**: Execute `make -C <build_dir>` (or `make -s -C <build_dir>` in non-verbose mode)
5. **Execute**: Run the resulting binary

### 6. Test Updates

The `test_verbose.t` test needs to be updated since the output will change from direct `ocamlc` commands to `make` output.

## Benefits

1. **Incremental builds**: Make handles dependency tracking automatically
2. **Parallel builds**: Can use `make -j` for parallel compilation
3. **Debuggability**: The Makefile is human-readable and can be inspected
4. **Standard tooling**: Developers familiar with Make can understand and debug builds

## Edge Cases to Consider

1. **No dependencies**: Script with no `[%%require]` should still work
2. **Deep dependency chains**: Makefile should handle any depth
3. **Diamond dependencies**: If A requires B and C, and both B and C require D, D should only be compiled once (handled naturally by Make)
4. **Path escaping**: Paths with spaces or special characters need proper escaping in Makefile

## Estimated Complexity

- Remove ~20 lines (compile, link, run_command)
- Add ~40-50 lines (Makefile generation, make invocation)
- Modify ~10 lines in `run` function
- Update 1 test file

Net change: approximately +30 lines

## Implementation Summary

### Changes Made

1. **Removed** `run_command`, `compile`, and `link` functions from `bin/main.ml`

2. **Added** `generate_makefile` function that creates Makefile content with:
   - `.PHONY: all` target
   - `.cmo` rules for each dependency (depending on `.ml` source and `.cmi` of required modules)
   - `.cmi` rules that depend on corresponding `.cmo` (since they're produced together)
   - Link rule for `a.out`

3. **Modified** `run` function to:
   - Write all source files and `includes.args` files (unchanged)
   - Generate and write `Makefile` to build directory
   - Run `make -s -C <build_dir>` (silent) or `make -C <build_dir>` (verbose)
   - Execute the resulting binary

4. **Updated tests** to expect `Makefile` in build artifacts and new verbose output format

### Deviation from Original Plan

- Used traditional Make syntax instead of `&:` grouped targets (GNU Make 4.3+ feature) for BSD make compatibility on macOS
- Instead of grouped targets, we use separate rules:
  - `.cmo` depends on `.ml` and required `.cmi` files (with recipe)
  - `.cmi` depends on `.cmo` (no recipe, since they're produced together)

### Files Changed

- `bin/main.ml` - Core implementation changes
- `test/test_verbose.t` - Updated expected output
- `test/test_build_dir.t` - Added `Makefile` to expected artifacts
- `test/test_build_dir_auto.t` - Added `Makefile` to expected artifacts
- `test/test_shebang.t` - Added `Makefile` to expected artifacts
