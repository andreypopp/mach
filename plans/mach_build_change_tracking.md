# Plan: mach_build.ml Change Tracking

## Overview

Add change tracking to `mach_build.ml` so it only rebuilds targets when their dependencies have changed. Use the same approach as Make: compare target mtime vs dependency mtimes directly.

## Current State

The `mach_build.ml` module:
- Parses build specifications (sexp format) with `Rule` and `Rule_dyndep` stanzas
- Builds targets via topological sort (deps before dependents)
- Has `rule.built` field but it's only used within a single build session
- Always rebuilds all targets, regardless of whether files changed

## Design

### Change Detection (Make-style)

A target needs rebuilding if:
1. Target file doesn't exist, OR
2. Any dependency has mtime newer than target's mtime

No state file needed - just compare mtimes at build time.

### Implementation

Add `needs_rebuild` check before `build_rule`:

```ocaml
let needs_rebuild (rule : rule) =
  let targets = rule_targets rule in
  (* Get oldest target mtime, or None if any target missing *)
  let target_mtime =
    Array.fold_left (fun acc target_path ->
      match acc, Mach_std.file_stat target_path with
      | None, _ -> None
      | _, None -> None
      | Some oldest, Some stat -> Some (min oldest stat.mtime)
    ) (Some max_int) targets
  in
  match target_mtime with
  | None -> true  (* target doesn't exist *)
  | Some target_mtime ->
    (* Check if any dep is newer *)
    Array.exists (fun dep_path ->
      match Mach_std.file_stat dep_path with
      | None -> true  (* dep missing, rebuild to get error *)
      | Some stat -> stat.mtime > target_mtime
    ) rule.deps
```

### Dyndep Handling

For dyndeps, the check happens after the dyndep file is built/loaded:
- First check if dyndep file itself needs rebuild
- After dyndep is ready, load discovered deps
- Check if any discovered dep is newer than the dependent target

### Build Flow Changes

In `build_rule`:
```ocaml
let build_rule t (rule : rule) =
  if rule.built then ...
  else if not (needs_rebuild rule) then begin
    (* Mark as built without running commands *)
    rule.built <- true
  end
  else begin
    (* existing build logic *)
    ...
  end
```

## Files to Modify

1. `lib/mach_build.ml` - Add `needs_rebuild` function, modify `build_rule`

## Testing

Add new test file `test/test_builder_incremental.t`:
1. Build a target
2. Build again without changes - should skip
3. Touch a dependency - should rebuild
4. Test with dyndeps
