# Plan: Test removing/adding files to dep graph

## Goal

Create comprehensive tests to verify that mach correctly handles dynamic changes
to the dependency graph, including:
- Adding new dependencies to existing scripts
- Removing dependencies from existing scripts
- Modifying dependency files
- Changes in transitive dependencies

## Background

The caching mechanism in `Mach_state` determines whether to recollect
dependencies:
1. `Mach_state.read` reads the cached state from `Mach.state` file
2. `Mach_state.is_fresh` checks if all files have same mtime/size
3. If state is fresh, skip recollection; otherwise, `Mach_state.collect` runs DFS
   again

### Current behavior analysis

Looking at `configure` function (main.ml:229-265):
```ocaml
let state, is_fresh =
  match Mach_state.read state_path with
  | Some st when Mach_state.is_fresh st -> st, true
  | _ -> Mach_state.collect source_path, false
in
```

The cache is invalidated when:
- `Mach.state` file doesn't exist
- Any file in the state has different mtime or size

**Potential issue**: If we only check mtime/size of files that were *previously*
in the dependency graph, we might miss new `#require` directives that add new
files. However, if the main script's mtime changes (which it does when we add
a new `#require`), the state becomes stale and we recollect.

Similarly, if we remove a `#require` directive, the main script's mtime changes,
triggering recollection.

## Test Scenarios

### Test 1: Add a new dependency

1. Create `main.ml` with no dependencies
2. Build and run → works
3. Create `lib.ml`
4. Modify `main.ml` to `#require "./lib.ml"`
5. Build and run → should work, lib should be in dep graph

### Test 2: Remove a dependency

1. Create `lib.ml` and `main.ml` with `#require "./lib.ml"`
2. Build and run → works
3. Modify `main.ml` to remove the `#require` directive and usage
4. Build and run → should work without lib

### Test 3: Modify a dependency

1. Create `lib.ml` (returns "v1") and `main.ml` requiring it
2. Build and run → prints "v1"
3. Modify `lib.ml` to return "v2"
4. Build and run → should print "v2"

### Test 4: Add transitive dependency

1. Create `lib_a.ml` (no deps) and `main.ml` requiring lib_a
2. Build and run → works
3. Create `lib_b.ml`
4. Modify `lib_a.ml` to `#require "./lib_b.ml"`
5. Build and run → should work with new transitive dep

### Test 5: Remove transitive dependency

1. Create `lib_b.ml`, `lib_a.ml` requiring lib_b, `main.ml` requiring lib_a
2. Build and run → works
3. Modify `lib_a.ml` to remove `#require "./lib_b.ml"` and usage
4. Build and run → should work without lib_b

### Test 6: Replace a dependency

1. Create `old_lib.ml`, `main.ml` requiring old_lib
2. Build and run → works
3. Create `new_lib.ml`
4. Modify `main.ml` to require new_lib instead of old_lib
5. Build and run → should use new_lib

## Implementation

Create a single test file `test/test_dep_graph_changes.t` covering these
scenarios. Each scenario should:
1. Set up initial files
2. Build/run to establish cached state
3. Make changes
4. Build/run again to verify correct behavior

The test file will follow the existing cram test patterns, using
`$XDG_CONFIG_HOME` to isolate build artifacts.

## Verification

After implementing, run `dune test` to verify all tests pass.

## Implementation Notes (Completed)

All 6 test scenarios were implemented in `test/test_dep_graph_changes.t`.

**Key discovery during implementation:** Tests require `sleep 1` between the
first run and subsequent file modifications. This is because:

1. Make uses file modification times (mtime) to determine if targets are stale
2. Filesystem mtime resolution is typically 1 second
3. If all operations happen within the same second, Make sees equal timestamps
   and skips rebuilding

The `sleep 1` must be placed AFTER the first `mach run` but BEFORE modifying
source files, ensuring the modified files have a newer timestamp than the
build artifacts from the first run.

The `Mach_state` caching mechanism correctly detects changes (verified by
inspecting `Mach.state` file contents), but Make needs different timestamps
to trigger rebuilds.
