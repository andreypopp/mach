# Plan: Support for ocamlfind libraries

## Overview

This plan describes how to add support for depending on ocamlfind libraries via `#require "libname"` directives. Currently, all `#require` directives are treated as file paths. We need to distinguish between:

- **File requires**: paths starting with `/`, `./`, or `../` - resolved as file dependencies
- **Library requires**: all other strings - treated as ocamlfind package names

## Current Architecture

The current flow is:

1. **`extract_requires`** (line 85-97): Parses `#require "..."` directives from source files
2. **`resolve_require`** (line 60-68): Resolves each require as a file path using `Unix.realpath`
3. **`Mach_state.collect_exn`**: Does DFS to collect all modules and their dependencies
4. **`configure_backend`**: Generates per-module `mach.mk` files with:
   - `includes.args`: Contains `-I=<build-dir>` for each dependency
   - Compilation rules that use `includes.args`
   - Link rule that uses `all_objects.args`

## Design

### Approach

1. Classify requires at parse time into file paths vs library names
2. Store library names in `Mach_state.entry` alongside file requires
3. During configure, collect all libraries from all modules and generate:
   - `lib_includes.args` in root build dir (compile-time include paths)
   - `lib_objects.args` in root build dir (link-time library objects)
4. Update compilation and linking commands to use these files

### Why generate args files via build system (make/ninja rules)

Generating `lib_includes.args` and `lib_objects.args` as build rules (rather than during configure) enables parallel execution when building multiple modules. The build system can run `ocamlfind query` commands in parallel with other independent tasks.

## Implementation Steps

### Step 1: Add is_require_path helper function

Add a helper to distinguish file paths from library names:

```ocaml
let is_require_path s =
  String.length s > 0 && (
    s.[0] = '/' ||
    String.starts_with ~prefix:"./" s ||
    String.starts_with ~prefix:"../" s
  )
```

### Step 2: Classify requires at parse time

Modify `extract_requires` to return both file requires and library requires:

```ocaml
(* Returns (file_requires, lib_requires) *)
let extract_requires source_path : string list * string list =
  let rec parse line_num (files, libs) ic =
    match In_channel.input_line ic with
    | None -> (List.rev files, List.rev libs)
    | Some line when is_shebang line -> parse (line_num + 1) (files, libs) ic
    | Some line when is_directive line ->
      let req = Scanf.sscanf line "#require %S%_s" Fun.id in
      if is_require_path req then
        let resolved = resolve_require ~source_path ~line req in
        parse (line_num + 1) (resolved :: files, libs) ic
      else
        parse (line_num + 1) (files, req :: libs) ic
    | Some line when is_empty_line line -> parse (line_num + 1) (files, libs) ic
    | Some _ -> (List.rev files, List.rev libs)
  in
  In_channel.with_open_text source_path (parse 1 ([], []))
```

**Files affected**: `lib/mach_lib.ml`

### Step 3: Update Mach_state.entry and ocaml_module to include libs

Update `Mach_state.entry`:

```ocaml
type entry = {
  ml_path: string;
  mli_path: string option;
  ml_stat: file_stat;
  mli_stat: file_stat option;
  requires: string list;  (* resolved file paths *)
  libs: string list;      (* ocamlfind library names *)
}
```

Also update `ocaml_module` type (used during configure):

```ocaml
type ocaml_module = {
  ml_path: string;
  mli_path: string option;
  cmx: string;
  cmi: string;
  cmt: string;
  module_name: string;
  build_dir: string;
  resolved_requires: string list;
  libs: string list;  (* ocamlfind library names for this module *)
}
```

**Files affected**: `lib/mach_lib.ml`

### Step 4: Update state serialization

Update `Mach_state.read` and `Mach_state.write` to handle libs:

The state file format needs a new line type for libs:

```
/path/to/script.ml 1234567890 1024
  requires /path/to/dep.ml
  lib cmdliner
  lib unix
```

In `write`:
```ocaml
List.iter (fun l -> Buffer.output_line oc (sprintf "  lib %s" l)) e.libs
```

In `read`:
```ocaml
| line :: rest when String.length line > 6 && String.sub line 0 6 = "  lib " ->
  let e = Option.get cur in
  let lib = Scanf.sscanf line "  lib %s" Fun.id in
  loop acc (Some { e with libs = lib :: e.libs }) rest
```

**Files affected**: `lib/mach_lib.ml`

### Step 5: Update collect_exn to populate libs

```ocaml
let rec dfs ml_path =
  if Hashtbl.mem visited ml_path then ()
  else begin
    Hashtbl.add visited ml_path ();
    let file_requires, lib_requires = extract_requires ml_path in
    List.iter dfs file_requires;
    let mli_path = mli_path_of_ml_if_exists ml_path in
    let mli_stat = Option.map file_stat mli_path in
    entries := {
      ml_path; mli_path;
      ml_stat = file_stat ml_path; mli_stat;
      requires = file_requires;
      libs = lib_requires
    } :: !entries
  end
in
```

**Files affected**: `lib/mach_lib.ml`

### Step 6: Update needs_reconfigure to check libs

In `needs_reconfigure`, when re-extracting requires from a changed file, also compare libs:

```ocaml
let file_requires, lib_requires = extract_requires entry.ml_path in
if file_requires <> entry.requires || lib_requires <> entry.libs
then (log_very_verbose "mach:state: requires/libs changed, need reconfigure"; true)
else false
```

**Files affected**: `lib/mach_lib.ml`

### Step 7: Generate lib_includes.args (per-module) and lib_objects.args (root)

**Per-module `lib_includes.args`** - Add to each module's `mach.mk` using only that module's own libs:

```ocaml
(* In configure_ocaml_module or a new function, add rule for lib_includes.args *)
let lib_includes = Filename.(m.build_dir / "lib_includes.args") in
if m.libs = [] then
  B.rulef b ~target:lib_includes ~deps:[] "touch %s" lib_includes
else begin
  let libs_str = String.concat " " m.libs in
  B.rulef b ~target:lib_includes ~deps:[]
    "ocamlfind query -i-format -recursive %s > %s" libs_str lib_includes
end
```

**Root `lib_objects.args`** - Add to root Makefile/build.ninja using all libs from all modules:

```ocaml
(* In root build file generation, collect all unique libs *)
let all_libs =
  List.fold_left (fun acc entry ->
    List.fold_left (fun acc lib ->
      if List.mem lib acc then acc else lib :: acc
    ) acc entry.Mach_state.libs
  ) [] state.Mach_state.entries
  |> List.rev
in

let lib_objects = Filename.(root_build_dir / "lib_objects.args") in
if all_libs = [] then
  B.rulef b ~target:lib_objects ~deps:[] "touch %s" lib_objects
else begin
  let libs_str = String.concat " " all_libs in
  B.rulef b ~target:lib_objects ~deps:[]
    "ocamlfind query -a-format -recursive -predicates native %s > %s" libs_str lib_objects
end
```

This separation ensures:
- Each module's compilation only depends on its own library includes
- Linking uses all library objects from all modules combined

**Files affected**: `lib/mach_lib.ml`

### Step 8: Update compilation rules to use lib_includes.args

In `compile_ocaml_module`, add the module's own `lib_includes.args` to ocamlc/ocamlopt commands.

The `lib_includes.args` is in the module's own build dir:

```ocaml
let compile_ocaml_module b (m : ocaml_module) =
  (* ... *)
  let lib_args = Filename.(m.build_dir / "lib_includes.args") in
  (* In compilation commands, add: -args lib_args *)
```

Modify compilation rules:
```ocaml
(* With .mli: *)
B.rulef b ~target:m.cmi ~deps:(mli :: args :: lib_args :: cmi_deps)
  "ocamlc -bin-annot -c -opaque -args %s -args %s -o %s %s" args lib_args m.cmi mli;
B.rulef b ~target:m.cmx ~deps:[ml; m.cmi; args; lib_args]
  "ocamlopt -bin-annot -c -args %s -args %s -cmi-file %s -o %s %s" args lib_args m.cmi m.cmx ml;

(* Without .mli: *)
B.rulef b ~target:m.cmx ~deps:(ml :: args :: lib_args :: cmi_deps)
  "ocamlopt -bin-annot -c -args %s -args %s -o %s %s" args lib_args m.cmx ml;
```

**Files affected**: `lib/mach_lib.ml`

### Step 9: Update linking rule to use lib_objects.args

In `link_ocaml_module`:

```ocaml
let link_ocaml_module b (all_objs : string list) ~exe_path =
  let root_build_dir = Filename.dirname exe_path in
  let args = Filename.(root_build_dir / "all_objects.args") in
  let lib_args = Filename.(root_build_dir / "lib_objects.args") in
  let objs_str = String.concat " " all_objs in
  B.rulef b ~target:args ~deps:all_objs "printf '%%s\\n' %s > %s" objs_str args;
  B.rulef b ~target:exe_path ~deps:(args :: lib_args :: all_objs)
    "ocamlopt -o %s -args %s -args %s" exe_path lib_args args
```

Note: `-args lib_objects.args` should come before `-args all_objects.args` because library objects are typically linked before the main object.

**Files affected**: `lib/mach_lib.ml`

### Step 10: Add test for ocamlfind library

Create `test/test_ocamlfind_lib.t`:

```
Isolate mach config to a test dir:
  $ . ../env.sh

Create a script that uses cmdliner:
  $ cat << 'EOF' > main.ml
  > #require "cmdliner";;
  >
  > let () =
  >   let open Cmdliner in
  >   let name = Arg.(value & opt string "World" & info ["n"; "name"] ~doc:"Name to greet") in
  >   let greet name = Printf.printf "Hello, %s!\n" name in
  >   let cmd = Cmd.v (Cmd.info "greet") Term.(const greet $ name) in
  >   exit (Cmd.eval cmd)
  > EOF

Test basic run:
  $ mach run ./main.ml
  Hello, World!

Test with argument:
  $ mach run ./main.ml -- -n Claude
  Hello, Claude!

Verify lib_includes.args was generated:
  $ test -f mach/build/*__main.ml/lib_includes.args && echo "exists"
  exists

Verify lib_objects.args was generated:
  $ test -f mach/build/*__main.ml/lib_objects.args && echo "exists"
  exists

Inspect lib_includes.args (should contain -I paths for cmdliner):
  $ grep -c "cmdliner" mach/build/*__main.ml/lib_includes.args
  [1-9]* (re)
```

**Files affected**: `test/test_ocamlfind_lib.t`

## Testing Strategy

1. **Unit test**: Create cram test with cmdliner library
2. **Verify generation**: Check lib_includes.args and lib_objects.args are created
3. **Verify content**: Check files contain expected paths/objects
4. **Verify argument passing**: Ensure compilation succeeds with library types
5. **Mixed usage**: Test script that uses both file requires and library requires
6. **Transitive libs**: If module A uses lib X, and module B requires A, compilation should still work

## Edge Cases

1. **No libraries**: If no ocamlfind libs are used, generate empty lib-*.args files
2. **Duplicate libraries**: If multiple modules require same library, deduplicate before calling ocamlfind
3. **Library not found**: ocamlfind will fail - propagate error as user error
4. **Mixed requires**: A module can have both file requires and lib requires

## Potential Issues

1. **Ordering**: Library archives may need to be linked in specific order. Using `ocamlfind query -a-format -recursive` should handle this.
2. **Transitive dependencies**: The `-recursive` flag to ocamlfind handles transitive library dependencies.

## Summary of Changes

| File | Change |
|------|--------|
| `lib/mach_lib.ml` | Add `is_require_path` helper function |
| `lib/mach_lib.ml` | Modify `extract_requires` to return file and lib requires |
| `lib/mach_lib.ml` | Add `libs` field to `Mach_state.entry` and `ocaml_module` |
| `lib/mach_lib.ml` | Update `Mach_state.read/write` for libs serialization |
| `lib/mach_lib.ml` | Update `Mach_state.collect_exn` to populate libs |
| `lib/mach_lib.ml` | Update `needs_reconfigure` to check libs |
| `lib/mach_lib.ml` | Add per-module `lib_includes.args` rule in mach.mk, `lib_objects.args` rule in root Makefile |
| `lib/mach_lib.ml` | Update `compile_ocaml_module` to use lib_includes.args |
| `lib/mach_lib.ml` | Update `link_ocaml_module` to use lib_objects.args |
| `test/test_ocamlfind_lib.t` | New test using cmdliner package |
