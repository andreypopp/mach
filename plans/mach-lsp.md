# Plan: Implement `mach-lsp` Command for LSP Support

## Overview

Create a new `mach-lsp` executable that provides LSP support for mach-based projects:

1. `mach-lsp` - starts `ocamllsp` with `OCAML_MERLIN_BIN=mach-lsp` set
2. `mach-lsp ocaml-merlin` - implements the merlin dot_protocol server

This enables IDE features like autocomplete, go-to-definition, and type information for mach scripts.

## Background

### How ocamllsp + merlin work together

1. `ocamllsp` is the OCaml Language Server Protocol implementation
2. For configuration (include paths, compiler flags), ocamllsp queries a "merlin config provider"
3. By default, this is `dune ocaml-merlin`
4. Our forked ocamllsp checks `OCAML_MERLIN_BIN` env var and calls `$OCAML_MERLIN_BIN ocaml-merlin`

**Reference:** `../ocaml-lsp/ocaml-lsp-server/src/merlin_config.ml`
- Lines 65-68: Checks `OCAML_MERLIN_BIN` env var, defaults to `"dune"`
- Lines 82-85: Calls `$bin ocaml-merlin` (without `--no-print-directory` for non-dune)
- Lines 110-128: `Dot_protocol_io` module wrapping `Merlin_dot_protocol`

### The merlin dot_protocol

The protocol uses canonical s-expressions (csexp) over stdin/stdout.

**Reference:** `_opam/lib/merlin-lib/dot_protocol/merlin_dot_protocol.mli`
- Lines 44-65: `Directive` module with all directive types (`S`, `B`, `FLG`, etc.)
- Lines 86-87: `command` type: `File of string | Halt | Unknown`
- Lines 89-108: `S` module signature with `read`, `write`, `Commands.read_input`, etc.
- Lines 131-135: `Blocking` module for synchronous stdin/stdout I/O

**Reference:** `_opam/lib/merlin-lib/dot_protocol/merlin_dot_protocol.ml`
- Lines 73-154: `Sexp` module for csexp parsing/serialization
- Lines 200-215: `Commands` implementation (`read_input`, `send_file`, `halt`)
- Lines 234-247: `Blocking` module using `Csexp.input`/`Csexp.to_channel`

**Reference:** `_opam/lib/csexp/csexp.mli`
- Canonical S-expression format: `<length>:<content>` (e.g., `4:File` = atom "File")
- `input : in_channel -> (sexp, string) result` - read one csexp
- `to_channel : out_channel -> sexp -> unit` - write one csexp

**Commands (from ocamllsp to server):**
- `(File "/path/to/file.ml")` - request config for a file (csexp: `(4:File<len>:<path>)`)
- `Halt` - stop the server (csexp: `4:Halt`)

**Response (from server to ocamllsp):**
A list of directives (wrapped in a csexp list):
- `(S "/path")` - source directory (for .ml files)
- `(B "/path")` - build directory (for .cmi/.cmo files)
- `(FLG ("-flag1" "-flag2"))` - compiler flags
- `(ERROR "message")` - error message

### What mach-lsp needs to provide

For a given `.ml` file that's part of a mach project:
1. Run `configure` to get the dependency graph and build directories
2. Return `S` directives for source directories of all dependencies
3. Return `B` directives for build directories (where .cmi files are)

**Reference:** `bin/main.ml` (existing mach implementation)
- Lines 17-19: `build_dir_of` - computes build directory for a source path
- Lines 86-174: `Mach_state` module - dependency state, collection, freshness check
- Lines 266-310: `configure` function - collects deps, generates Makefiles, returns state

## Implementation

### 1. Create New Executable

Create `bin/mach_lsp.ml` as a separate executable that shares code with `mach`:

**Option A: Shared library approach**
- Extract shared code into `lib/mach_lib.ml`
- Both `mach` and `mach-lsp` depend on this library

**Option B: Single file duplication (simpler for now)**
- Copy necessary functions (`configure`, `Mach_state`, `build_dir_of`, etc.)
- Or use OCaml's `#use` directive during development

**Recommended: Option A** - Create a library to avoid code duplication.

### 2. Project Structure

```
bin/
  main.ml       -- mach executable (existing)
  mach_lsp.ml   -- mach-lsp executable (new)
  dune          -- updated to build both executables
lib/
  mach_lib.ml   -- shared code extracted from main.ml
  dune          -- library definition
```

### 3. Update `dune` files

lib/dune
```dune
(library
 (name mach_lib)
 (libraries unix))
```

bin/dune
```dune
(executable
 (public_name mach)
 (name main)
 (libraries mach_lib cmdliner unix))

(executable
 (public_name mach-lsp)
 (name mach_lsp)
 (libraries mach_lib cmdliner unix csexp merlin-lib.dot_protocol))
```

### 4. Implement `mach-lsp` (`bin/mach_lsp.ml`)

```ocaml
(* mach-lsp - LSP support for mach projects *)

open Printf
open Mach_lib  (* shared code from mach *)

(* --- Merlin server --- *)

module Merlin_server = struct
  module Protocol = Merlin_dot_protocol.Blocking

  let directives_for_file path : Merlin_dot_protocol.directive list =
    try
      let path = Unix.realpath path in
      let state, _root_module, _exe_path = configure path in
      let directives = ref [] in
      List.iter (fun (entry : Mach_state.entry) ->
        let build_dir = build_dir_of entry.ml_path in
        let source_dir = Filename.dirname entry.ml_path in
        directives := `B build_dir :: `S source_dir :: !directives
      ) state.entries;
      List.rev !directives
    with
    | Failure msg -> [`ERROR_MSG msg]
    | Unix.Unix_error (err, _, arg) ->
      [`ERROR_MSG (sprintf "%s: %s" (Unix.error_message err) arg)]
    | _ -> [`ERROR_MSG "Unknown error computing merlin config"]

  let run () =
    let rec loop () =
      match Protocol.Commands.read_input stdin with
      | Halt -> ()
      | Unknown -> loop ()
      | File path ->
        let directives = directives_for_file path in
        Protocol.write stdout directives;
        flush stdout;
        loop ()
    in
    loop ()
end

(* --- Start ocamllsp --- *)

let start_lsp () =
  (* Find ocamllsp binary *)
  let ocamllsp_path =
    let paths = String.split_on_char ':' (Sys.getenv_opt "PATH" |> Option.value ~default:"") in
    let rec find = function
      | [] -> failwith "ocamllsp not found in PATH"
      | dir :: rest ->
        let path = Filename.concat dir "ocamllsp" in
        if Sys.file_exists path then path else find rest
    in
    find paths
  in
  (* Find mach-lsp binary (ourselves) *)
  let mach_lsp_path = Unix.realpath Sys.executable_name in
  (* Set OCAML_MERLIN_BIN and exec ocamllsp *)
  Unix.putenv "OCAML_MERLIN_BIN" mach_lsp_path;
  Unix.execv ocamllsp_path [| ocamllsp_path; "--stdio" |]

(* --- CLI --- *)

open Cmdliner

let ocaml_merlin_cmd =
  let doc = "Merlin configuration server (called by ocamllsp)" in
  let info = Cmd.info "ocaml-merlin" ~doc in
  Cmd.v info Term.(const Merlin_server.run $ const ())

let cmd =
  let doc = "Start OCaml LSP server with mach support" in
  let info = Cmd.info "mach-lsp" ~doc in
  let default = Term.(const start_lsp $ const ()) in
  Cmd.group ~default info [ocaml_merlin_cmd]

let () = exit (Cmdliner.Cmd.eval cmd)
```

### 5. Handle Edge Cases

**Files not part of a mach project:**
- If `configure` fails (no `#require` directives found), return empty directives
- ocamllsp will fall back to basic behavior

**Path handling:**
- ocamllsp may send relative or absolute paths
- Use `Unix.realpath` to normalize (already done)
- Handle non-existent files gracefully

### 6. Testing Strategy

Create `test/test_mach_lsp.t`:

```
Test mach-lsp ocaml-merlin subcommand

  $ cat > lib.ml << 'EOF'
  > let x = 42
  > EOF

  $ cat > main.ml << 'EOF'
  > #require "./lib.ml"
  > let () = print_int Lib.x
  > EOF

Test File command returns directives:
  $ printf '(4:File7:main.ml)' | mach-lsp ocaml-merlin 2>/dev/null
  [csexp output with S and B directives]

Test Halt command exits cleanly:
  $ printf '4:Halt' | mach-lsp ocaml-merlin
  [no output, clean exit]
```

## Implementation Steps

1. **Extract shared code** - Create `lib/mach_lib.ml` with `configure`, `Mach_state`, etc.
2. **Update dune files** - Add library and new executable
3. **Implement `mach-lsp`** - Main executable with `start_lsp` and `ocaml-merlin` subcommand
4. **Implement `Merlin_server`** - Protocol handling and directive computation
5. **Update `mach`** - Use shared library instead of inline code
6. **Write tests** - Protocol compliance tests
7. **Integration test** - Manual testing with ocamllsp fork

## Usage

```bash
# Start LSP server (for editor integration)
mach-lsp

# Or configure editor to run mach-lsp directly
# VSCode settings.json:
# "ocaml.server.command": ["mach-lsp"]
```

## Potential Issues

1. **Finding ocamllsp** - Need to locate the forked ocamllsp binary
2. **csexp format** - Must output valid canonical s-expressions
3. **Performance** - `configure` called per file query; may need caching later
4. **Stdlib paths** - May need to add `STDLIB` directive

## Future Enhancements

1. **Caching** - Cache configured state per project root
2. **Incremental updates** - Watch for file changes
3. **Package support** - Include paths for `#require "pkg"` when implemented
4. **Error reporting** - Better error messages in LSP diagnostics
