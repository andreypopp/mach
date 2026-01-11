# Reconfiguration Fixes Plan

## Problem Statement

Currently, `mach` may fail to reconfigure when it should in two scenarios:

1. **Build backend changes**: If a user switches from `make` to `ninja` (or vice versa), the existing build files won't be regenerated
2. **Mach path changes**: If the `mach` binary is recompiled/moved, the generated build files contain stale paths to the `mach pp` command

## Current State Analysis

### Mach.state File Format

The `Mach.state` file (in `lib/mach_lib.ml:201-208`) currently stores:
```
<ml_path> <mtime> <size>
  mli <mtime> <size>        # optional
  requires <path>           # zero or more
  lib <name>                # zero or more
```

### Mach Path Detection

The mach executable path is computed in `configure_backend` (lines 285-294):
```ocaml
let cmd =
  match Sys.backend_type with
  | Sys.Native -> Sys.executable_name
  | Sys.Bytecode ->
    let path = Sys.argv.(0) in
    if Filename.is_relative path then Filename.(Sys.getcwd () / path) else path
    ...
```

This code is embedded in `configure_backend` but needs to be:
1. Extracted to a helper function
2. Made available to store in state and check for changes

### Build Backend

The `build_backend` type is defined at line 252:
```ocaml
type build_backend = Make | Ninja
```

It's passed through `configure_exn`, but not stored in state.

## Implementation Plan

### Step 1: Add Helper Function for Mach Path

Extract the mach path computation to a helper function in the Utilities section:

```ocaml
let mach_executable_path () =
  match Sys.backend_type with
  | Sys.Native -> Unix.realpath Sys.executable_name
  | Sys.Bytecode ->
    let script =
      let path = Sys.argv.(0) in
      if Filename.is_relative path then Filename.(Sys.getcwd () / path) else path
    in
    Printf.sprintf "%s -I +unix unix.cma %s"
      (Filename.quote Sys.executable_name) (Filename.quote (Unix.realpath script))
  | Sys.Other _ -> failwith "mach must be run as a native/bytecode executable"
```

Note: For native, we use `Unix.realpath` to get the canonical path, making it consistent across invocations.

### Step 2: Extend Mach_state Module

Modify the `Mach_state` module to track build metadata:

1. Add new type for build metadata:
```ocaml
type metadata = {
  build_backend: build_backend;
  mach_path: string;
}
```

2. Update the state type:
```ocaml
type t = {
  metadata: metadata;
  root: entry;
  entries: entry list;
}
```

3. Update `read` to parse metadata (with backward compatibility - treat missing metadata as needing reconfigure)

4. Update `write` to output metadata at the start of the file

5. Update `needs_reconfigure` to check metadata against current values

### Step 3: New Mach.state File Format

The new format will be:
```
build_backend <make|ninja>
mach_path <absolute/path/to/mach>

<ml_path> <mtime> <size>
  mli <mtime> <size>
  requires <path>
  lib <name>
...
```

The metadata lines at the top, followed by a blank line, then the existing entry format.

### Step 4: Update configure_exn

1. Pass `build_backend` to `Mach_state.collect_exn` (or create metadata separately)
2. Compare stored metadata with current metadata in `needs_reconfigure` check
3. Update the `cmd` variable in `configure_backend` to use the helper

### Step 5: Signature Updates

Update `Mach_state` signature:
```ocaml
val read : build_backend:build_backend -> string -> t option
val write : string -> t -> unit  (* metadata included in t *)
val needs_reconfigure : t -> bool  (* checks metadata too *)
val collect_exn : build_backend:build_backend -> string -> t
val collect : build_backend:build_backend -> string -> (t, error) result
```

Or alternatively, make metadata checking explicit:
```ocaml
val needs_reconfigure : build_backend:build_backend -> mach_path:string -> t -> bool
```

I prefer the second approach as it's more explicit and doesn't require threading `build_backend` through everywhere.

## Detailed Implementation

### Changes to lib/mach_lib.ml

#### 1. Add mach_executable_path helper (after line 76, in Utilities section)

```ocaml
let mach_executable_path =
  lazy (
    match Sys.backend_type with
    | Sys.Native -> Unix.realpath Sys.executable_name
    | Sys.Bytecode ->
      let script =
        let path = Sys.argv.(0) in
        if Filename.is_relative path then Filename.(Sys.getcwd () / path) else path
      in
      Printf.sprintf "%s -I +unix unix.cma %s"
        (Filename.quote Sys.executable_name) (Filename.quote (Unix.realpath script))
    | Sys.Other _ -> failwith "mach must be run as a native/bytecode executable"
  )
let mach_executable_path () = Lazy.force mach_executable_path
```

#### 2. Update Mach_state types (starting at line 120)

```ocaml
module Mach_state : sig
  type file_stat = { mtime: int; size: int }
  type entry = { ml_path: string; mli_path: string option; ml_stat: file_stat; mli_stat: file_stat option; requires: string list; libs: string list }
  type metadata = { build_backend: build_backend; mach_path: string }
  type t = { metadata: metadata; root: entry; entries: entry list }

  val read : string -> t option
  val write : string -> t -> unit
  val needs_reconfigure : build_backend:build_backend -> mach_path:string -> t -> bool
  val collect_exn : build_backend:build_backend -> mach_path:string -> string -> t
  val collect : build_backend:build_backend -> mach_path:string -> string -> (t, error) result

  (* ... rest unchanged ... *)
end
```

#### 3. Update read function to parse metadata

Parse the first two lines as metadata, then continue with existing parsing logic.

#### 4. Update write function to output metadata

Write metadata lines first, then the entry lines.

#### 5. Update needs_reconfigure

Add check for metadata changes:
```ocaml
let needs_reconfigure ~build_backend ~mach_path state =
  if state.metadata.build_backend <> build_backend then
    (log_very_verbose "mach:state: build backend changed, need reconfigure"; true)
  else if state.metadata.mach_path <> mach_path then
    (log_very_verbose "mach:state: mach path changed, need reconfigure"; true)
  else
    (* existing entry checks *)
```

#### 6. Update configure_backend to use helper

Replace the inline `cmd` computation with:
```ocaml
let cmd = mach_executable_path () in
```

#### 7. Update configure_exn

Pass `mach_path` to the state functions and store metadata.

## Test Plan

Create a new test file `test/test_reconfigure_metadata.t`:

1. Test build backend change detection:
   - Build with make backend
   - Switch to ninja backend
   - Verify reconfiguration happens

2. Test mach path change detection:
   - This is harder to test directly since we can't easily change the mach path
   - Could potentially test by manually editing Mach.state

## Files to Modify

1. `lib/mach_lib.ml` - Main implementation changes
2. `test/test_reconfigure_metadata.t` - New test file
