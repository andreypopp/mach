# Plan: Reorganize Build

## Goal

Move dependency resolution and configuration logic from generated Makefiles into `mach` itself. Keep using Make for actual build execution but have `mach` handle all the "smart" parts.

## Current Architecture

Currently:
1. `mach configure SCRIPT.ml` generates a `mach.mk` that:
   - Has rules for generating more `mach.mk` files for dependencies (recursive)
   - Has rules for preprocessing (stripping `[%%require]`)
   - Has rules for compiling `.cmo` files
2. `mach build` generates a root `Makefile` that includes `mach.mk` and adds linking rules
3. `make` is invoked, which recursively generates all `mach.mk` files and builds

The problem: Complex logic is split between OCaml and Makefile. Makefile handles recursive dependency discovery via rules that invoke `mach configure`.

## New Architecture

### Flow on each `mach SCRIPT.ml` invocation:

1. **Read State Cache** (in `mach`):
   - Read `Mach.state` from build dir (if exists)
   - Validate freshness: check mtime/size of all files listed
   - If fresh → use state directly (it has all dependency info)
   - If stale or missing → discard, go to step 2

2. **Collect Dependencies** (only if state is stale/missing):
   - Parse `SCRIPT.ml`, extract `[%%require]` directives
   - Recursively do the same for each dependency (DFS)
   - Build new `Mach_state` with file stats and requires

3. **Generate Build Files** (only if state was regenerated):
   - For each module in state:
     - Ensure build dir exists
     - Write `mach.mk` with rules for preprocessing and compiling
   - Write root `Makefile` that includes all `mach.mk` files and has linking rule
   - Write new `Mach.state` to disk

4. **Build Execution** (via `make`):
   - Invoke `make -C <build_dir> all`
   - Make handles incremental builds based on file timestamps

5. **Run** (existing):
   - `Unix.execv` the resulting binary

### Mach.state Format

```
# Format: <path> <mtime> <size>
#   requires <dependency-path>
/path/to/main.ml 1704820000.0 1234
  requires /path/to/lib_a.ml
/path/to/lib_a.ml 1704819000.0 567
  requires /path/to/lib_b.ml
/path/to/lib_b.ml 1704818000.0 234
```

### Key Changes to main.ml

#### 1. Add Mach_state Module

```ocaml
(* Keeps state of a dependency graph with file stats *)
module Mach_state : sig
  type file_stat = { mtime: float; size: int }
  type entry = { path: string; stat: file_stat; requires: string list }
  type t  (* list of entries, topo-sorted *)

  val file_stat : string -> file_stat
  val read : string -> t option          (* read from disk, None if missing/corrupt *)
  val write : string -> t -> unit        (* write to disk *)
  val is_fresh : t -> bool               (* check all files have same mtime/size *)
  val collect : string -> t              (* DFS from entry point, parse all files *)
  val to_list : t -> entry list          (* topo-sorted, dependencies first *)
  val root : t -> entry                  (* get root entry *)
end
```

#### 2. Modify Configure

Current `configure` generates a recursive `mach.mk`. New version:

```ocaml
let configure source_path =
  let source_path = Unix.realpath source_path in
  let state_path = Filename.(default_build_dir source_path / "Mach.state") in

  (* Try to use cached state, otherwise collect fresh *)
  let state, is_fresh =
    match Mach_state.read state_path with
    | Some st when Mach_state.is_fresh st -> st, true
    | _ -> Mach_state.collect source_path, false
  in

  (* Generate mach.mk for each module (only if state changed) *)
  if not is_fresh then begin
    Mach_state.to_list state |> List.iter (fun entry ->
      let m = make_ocaml_module entry.path entry.requires in
      let mk_path = Filename.(m.build_dir / "mach.mk") in
      write_file mk_path (generate_module_mk m)
    );
    Mach_state.write state_path state
  end;

  (* Return root module for linking *)
  let root = Mach_state.root state in
  make_ocaml_module root.path root.requires
```

#### 3. Simplify Makefile Generation

Each module's `mach.mk` becomes simpler (no more recursive `mach configure` rules):

```makefile
# mach.mk for /path/to/lib_a.ml
$(BUILD_DIR)/Lib_a.ml: /path/to/lib_a.ml
	mach preprocess /path/to/lib_a.ml -o $(BUILD_DIR)

$(BUILD_DIR)/Lib_a.cmo: $(BUILD_DIR)/Lib_a.ml $(DEP_CMIS)
	ocamlc -c -args $(BUILD_DIR)/includes.args -o $@ $<
```

The root `Makefile`:

```makefile
MACH_OBJS :=

include /path/to/lib_b/mach.mk
include /path/to/lib_a/mach.mk
include /path/to/main/mach.mk

.PHONY: all
all: $(BUILD_DIR)/a.out

$(BUILD_DIR)/a.out: $(MACH_OBJS)
	ocamlc -o $@ $(MACH_OBJS)
```

### Implementation Steps

1. **Add `Mach_state` module** (~80 lines)
   - `file_stat` type for mtime/size
   - `entry` type with path, stat, requires
   - `read` / `write` for Mach.state file format
   - `is_fresh` to validate all files unchanged
   - `collect` to DFS from entry point and build state (reuses existing `parse_and_preprocess`)

2. **Refactor `configure`** (~15 lines)
   - Read cached state or collect fresh
   - Generate all mach.mk files upfront
   - Write state after generation

3. **Simplify Makefile generation** (~10 lines)
   - Remove recursive `mach configure` rules from mach.mk
   - Keep only preprocessing and compilation rules

4. **Update tests** (verify existing tests pass)

### Testing Strategy

1. All existing tests should pass unchanged (behavior is the same)
2. Add test for cache behavior:
   - Run twice, second run should be faster
   - Modify file, should trigger rebuild

### Risks and Mitigations

1. **Performance of OCaml parsing on each run**
   - Mitigated by state cache - skip parsing if mtimes unchanged

2. **State file corruption**
   - If state file is corrupted/invalid, treat as cache miss (regenerate all)

3. **Clock skew / mtime precision**
   - Use both mtime and size for comparison
   - If either differs, treat as changed

## Summary

The refactoring moves "intelligence" into `mach`:
- **Before**: Make discovers dependencies by invoking `mach configure` for each file
- **After**: `mach` discovers all dependencies upfront, generates all build files, Make just executes

Benefits:
- Simpler Makefiles (just build rules, no recursive generation)
- Easier to add features (all logic in OCaml)
- State cache enables fast "no-op" builds when nothing changed

## Implementation Summary (Completed)

### Changes Made

1. **Added `Mach_state` module** (~85 lines in `bin/main.ml:95-178`)
   - `file_stat` type for tracking mtime/size
   - `entry` type with path, stat, and requires
   - `read`/`write` for `Mach.state` file persistence
   - `is_fresh` to validate all files unchanged
   - `collect` does DFS from entry point, builds topo-sorted state
   - `to_list` and `root` accessors

2. **Refactored `configure`** (`bin/main.ml:271-293`)
   - Reads cached state or collects fresh
   - Generates mach.mk for all modules only when stale
   - Writes state after generation
   - Returns `Mach_state.t` instead of `ocaml_module`

3. **Simplified Makefile generation**
   - Removed recursive `mach configure` rules from mach.mk
   - Removed `-include` statements from mach.mk
   - Each mach.mk now only has: guard, MACH_OBJS append, preprocessing rule, compilation rule
   - Root Makefile explicitly includes all mach.mk files in topo order

4. **Updated `build`** (`bin/main.ml:297-321`)
   - Uses state to include all mach.mk files
   - Gets root module via `Mach_state.root`

### Files Modified
- `bin/main.ml` - main implementation
- `test/test_shebang.t` - updated to expect `Mach.state` file
- `test/test_simple.t` - updated to expect `Mach.state` file
- `test/test_build_dir_auto.t` - updated to expect `Mach.state` file

### All Tests Pass
