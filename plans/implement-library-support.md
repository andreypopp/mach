# Implementation Plan: Library Support

## Summary

Add support for libraries in mach. A library is a directory containing a `Machlib` file that defines the library's dependencies. All `.ml`/`.mli` files in that directory (excluding subdirectories) become modules of that library. Libraries are compiled into `.cmxa` archives.

## Key Design Decisions

### 1. Library Identification

A directory is a library if and only if it contains a `Machlib` file. When a script or module uses `#require "./some_lib"` where `some_lib` is a directory with a `Machlib` file, it's treated as a library reference rather than a single module.

### 2. Machlib File Format

S-expression format matching the existing state file style:

```
((require
  ("./some_mod.ml"
   "./other_lib")))
```

Note: ocamlfind libraries are also specified in require, distinguished by the absence of `/` in the path (same as `#require` in modules).

### 3. Library Build Output

Each library produces:
- `<libname>.cmxa` - Native archive (for linking)
- `<libname>.a` - Object archive (native code companion)
- `*.cmi` files - For each module (for compilation of dependents)
- `*.cmx` files - For each module (optional inlining info)

### 4. Build Directory Structure for Libraries

```
$MACH_HOME/_mach/build/<normalized-lib-path>/
  Mach.state           # Tracks library state
  <module>.ml          # Implementation (mlx -> ml if applicable)
  <module>.mli         # Interface (if exists)
  <module>.cmi         # Compiled interface
  <module>.cmx         # Compiled native code
  <module>.o           # Object file
  <module>.dep         # ocamldep output for <module>
  <libname>.cmxa       # Library archive
  <libname>.a          # Native archive companion
  mach.ninja           # Per-library build rules
  includes.args        # Include paths to dependencies
  lib_includes.args    # Include paths for ocamlfind libs
```

### 5. State Extension

Extend `Mach_state` with a new variant for library entries:

```ocaml
type entry =
  | Entry_module of module_entry
  | Entry_lib of lib_entry

and module_entry = {
  ml_path : string;
  mli_path : string option;
  ml_stat : file_stat;
  mli_stat : file_stat option;
  requires : string with_loc list;
  libs : lib with_loc list;
}

and lib_entry = {
  lib_path : string;              (* absolute path to library directory *)
  machlib_stat : file_stat;       (* mtime/size of Machlib file *)
  dir_stat : file_stat;           (* mtime/size of directory itself *)
  modules : lib_module list;      (* modules in this library *)
  requires : string with_loc list; (* other modules/libs this lib needs *)
  libs : lib with_loc list;       (* ocamlfind libraries *)
}

and lib_module = {
  ml_file : string;               (* relative filename, e.g., "foo.ml" *)
  mli_file : string option;       (* relative filename if exists *)
}
```

## Implementation Steps

### Step 1: Parse Machlib Files

**File: lib/mach_library.ml (new module)**

Add a function to parse `Machlib` files:

```ocaml
let parse_machlib path =
  (* Parse s-expression format, extract require list *)
  (* Validate paths exist, return (file_requires, lib_requires) *)
```

This is similar to `extract_requires_exn` but for the `Machlib` format.

### Step 2: Detect Library vs Module

**File: lib/mach_library.ml**

When resolving a require path:
1. If path points to a `.ml` file → module (existing behavior)
2. If path points to a directory with `Machlib` → library
3. If path is just a name without `/` → ocamlfind library (existing behavior)

```ocaml
type require_target =
  | Require_module of string      (* path to .ml file *)
  | Require_lib of string         (* path to directory with Machlib *)
  | Require_ocamlfind of string   (* ocamlfind library name *)

let resolve_require ~source_dir req =
  let path = if Filename.is_relative req then source_dir / req else req in
  if Sys.is_directory path then
    if Sys.file_exists (path / "Machlib") then Require_lib path
    else error "directory %s has no Machlib file" path
  else if String.contains req '/' then
    Require_module (path ^ ".ml")
  else
    Require_ocamlfind req
```

### Step 3: Extend State Collection

**File: lib/mach_state.ml**

Modify `collect_exn` to handle libraries:

```ocaml
let rec collect ~visited path =
  if Hashtbl.mem visited path then ()
  else begin
    Hashtbl.add visited path ();
    match classify_path path with
    | Module ml_path ->
        (* existing module collection logic *)
        let requires, libs = Mach_module.extract_requires_exn ml_path in
        List.iter (fun r -> collect ~visited r.v) requires;
        entries := Entry_module { ... } :: !entries
    | Library lib_path ->
        let machlib = lib_path / "Machlib" in
        let requires, libs = parse_machlib machlib in
        let modules = discover_lib_modules lib_path in
        List.iter (fun r -> collect ~visited r.v) requires;
        entries := Entry_lib { lib_path; modules; requires; libs; ... } :: !entries
  end
```

### Step 4: Library Module Discovery

**File: lib/mach_library.ml**

```ocaml
let discover_lib_modules lib_path =
  Sys.readdir lib_path
  |> Array.to_list
  |> List.filter_map (fun name ->
      if Filename.extension name = ".ml" then
        let ml_file = name in
        let mli_file =
          let candidate = Filename.remove_extension name ^ ".mli" in
          if Sys.file_exists (lib_path / candidate) then Some candidate else None
        in
        Some { ml_file; mli_file; ... }
      else None)
```

### Step 5: Library Build Configuration

**File: lib/mach_library.ml**

For each library, generate `mach.ninja` with:
- Preprocess rules for each .ml/.mli (copy, or mlx preprocessing if needed)
- ocamldep rules to discover intra-library dependencies (run by ninja)
- Compile rules for each module
- Archive rule to create .cmxa

```ninja
# Run ocamldep for each module (generates .dep file with dependencies)
build foo.dep: cmd foo.ml includes.args
  cmd = mach dep foo.ml -o foo.dep -args includes.args

build bar.dep: cmd bar.ml includes.args
  cmd = mach dep bar.ml -o bar.dep -args includes.args

# Per-module compilation
# Dependencies on other modules' .cmi are parsed from .dep files
build foo.cmx foo.cmi: cmd foo.ml foo.dep includes.args
  cmd = ocamlopt -c -I . -args includes.args -impl foo.ml
  dyndep = foo.dep

build bar.cmx bar.cmi: cmd bar.ml bar.dep includes.args
  cmd = ocamlopt -c -I . -args includes.args -impl bar.ml
  dyndep = bar.dep

# Archive creation (all .cmx files)
build mylib.cmxa mylib.a: cmd foo.cmx bar.cmx
  cmd = ocamlopt -a -o mylib.cmxa foo.cmx bar.cmx
```

**Note on dyndep**: Ninja's dynamic dependency feature reads additional dependencies from a file at build time. The `.dep` file format from ocamldep needs to be converted to ninja's dyndep format:

```
ninja_dyndep_version = 1
build foo.cmx: dyndep | bar.cmi
```

We add a new `mach dep` subcommand that runs ocamldep and converts its output to ninja dyndep format:

```bash
mach dep foo.ml -o foo.dep -args includes.args
```

The ninja rules then become:

```ninja
build foo.dep: cmd foo.ml includes.args
  cmd = mach dep foo.ml -o foo.dep -args includes.args
```

### Step 6: Library Linking

**File: lib/mach_library.ml**

When linking a script that depends on libraries:

1. Add library build directories to include path (for .cmi files)
2. Add library .cmxa files to link command
3. Ensure proper ordering (dependencies before dependents)

```ocaml
let link_with_libs b ~exe_path ~all_objs ~all_libs ~mach_libs =
  (* mach_libs: list of (lib_name, lib_cmxa_path) *)
  let lib_args = List.map snd mach_libs in
  (* Order: ocamlfind libs first, then mach libs (deps before dependents), then script modules *)
  Ninja.rule b ~target:exe_path ~deps:(all_objs @ lib_args)
    [sprintf "ocamlopt -o %s %s -args %s" exe_path (String.concat " " lib_args) objs_args]
```

### Step 7: Reconfiguration Check for Libraries

**File: lib/mach_state.ml (modify check_reconfigure_exn)**

For libraries, check:
1. `Machlib` file changed → full reconfigure (dependencies changed)
2. Directory mtime changed → reconfigure (modules may have been added/removed)
3. Module source changes → ninja handles rebuild via .dep file dependencies

```ocaml
let check_lib_reconfigure lib_entry =
  let machlib = lib_entry.lib_path / "Machlib" in
  let machlib_stat = stat machlib in
  if machlib_stat <> lib_entry.machlib_stat then
    Reconfigure_full
  else
    let dir_stat = stat lib_entry.lib_path in
    if dir_stat.mtime <> lib_entry.dir_stat.mtime then
      (* Directory changed, need to re-list modules *)
      Reconfigure_modules
    else
      (* No reconfigure needed - ninja handles source file changes *)
      No_reconfigure
```

### Step 8: MLX Support in Libraries

Library modules can be `.mlx` files. During preprocessing:
1. Copy `.ml` files as-is (no `#require` processing needed)
2. Preprocess `.mlx` files through the mlx preprocessor

### Step 9: Add `mach dep` Subcommand

**File: bin/mach.ml**

Add a new `dep` subcommand that:
1. Runs `ocamldep -native -one-line` on the input file
2. Parses the output (format: `foo.cmx: bar.cmi baz.cmi`)
3. Outputs ninja dyndep format

```ocaml
let dep_cmd ~input ~output ~args =
  let deps = run_cmd_lines "ocamldep -native -one-line -args %s %s" args input in
  (* Parse: "foo.cmx: bar.cmi baz.cmi" -> ["bar.cmi"; "baz.cmi"] *)
  let target, deps = parse_ocamldep_line (List.hd deps) in
  Out_channel.with_open_text output (fun oc ->
    fprintf oc "ninja_dyndep_version = 1\n";
    fprintf oc "build %s: dyndep | %s\n" target (String.concat " " deps))
```

Usage:
```bash
mach dep foo.ml -o foo.dep --args includes.args
```

### Step 10: Tests

Add cram tests for:
1. Basic library creation and usage
2. Library with multiple modules
3. Library depending on another library
4. Library depending on ocamlfind packages
5. Incremental rebuild when library module changes
6. Error handling for missing Machlib
7. Error handling for invalid Machlib format
8. `mach dep` command output format

## File Changes Summary

| File | Changes |
|------|---------|
| `lib/mach_library.ml` | New module: Machlib parsing, module discovery, build configuration, linking |
| `lib/mach_library.mli` | Interface for mach_library |
| `lib/mach_state.ml` | Add `Entry_lib` variant, `lib_entry` type, library state tracking |
| `lib/mach_state.mli` | Export new types |
| `lib/mach_lib.ml` | Call into mach_library for library entries |
| `lib/dune` | Add mach_library to library modules |
| `bin/mach.ml` | Add `dep` subcommand for ocamldep → ninja dyndep conversion |
| `test/test_lib.t` | New test file for library support |

## Risks and Mitigations

1. **Circular dependencies between libraries**:
   - Detect during collection, raise error with helpful message

2. **Module name conflicts across libraries**:
   - Each library is its own namespace
   - Modules from different libraries won't conflict due to separate build dirs

3. **Build order complexity**:
   - Libraries must be built before modules that depend on them
   - Use Ninja's dependency tracking for correct ordering

4. **Performance with large libraries**:
   - Ninja runs ocamldep incrementally (only for changed modules)
   - Ninja caches .dep files and only reruns when source changes

## Out of Scope

1. **Library versioning**: Libraries don't have explicit versions
2. **Library packaging/distribution**: Libraries are local only
3. **Bytecode compilation**: Only native compilation supported
4. **Wrapped libraries**: All modules are exposed (no namespace wrapping)
