# Plan: mach deps SCRIPT subcommand

## Goal

Implement a new subcommand `mach deps SCRIPT` that prints all dependencies of the given script with their SHA256 hashes and whether they are present in the store.

**Expected output format:**
```
/absolute/path/to/dependency1.ml <sha256 of dependency1.ml> in-store
/absolute/path/to/dependency2.ml <sha256 of dependency2.ml> not-in-store
...
```

## Analysis

### Existing infrastructure to leverage

1. **`collect_deps entry_path`** (line 152-173): DFS traversal with cycle detection, returns dependencies in topological order.

2. **`compute_hash ~dep_hashes ~preprocessed_content`** (line 122-124): Computes the cache key hash from dependency hashes and preprocessed source.

3. **`preprocess_to_string source_path`** (line 106-118): Parses and filters out `[%%require]` nodes, returns preprocessed source.

4. **`find_in_cache ~store_dir ~hash ~module_name`** (line 129-136): Checks if compiled artifacts exist in store.

5. **`extract_requires`** (line 67-94): Gets require paths from a source file.

6. **Cmdliner setup** (line 277-290): Existing CLI structure with `run` and `store-cleanup` commands.

### Design decisions

1. **What to hash**: same hash should be produces as while running the script. Factor out a common code if needed.

2. **Include entry script or not**: The TODO says "prints all dependencies", which typically means transitive dependencies, not the script itself. However, for completeness and consistency with how `collect_deps` works, we'll include the entry script. Users can easily filter it out if needed.

3. **Output order**: Topological order (dependencies before dependents), matching how `collect_deps` returns them. This is useful for build systems.

4. **Store argument**: Required since we need to check if artifacts are in cache. Reuse existing `store_arg`.

## Implementation steps

### Step 1: Extract `resolve_deps` function

Factor out a shared function from `run` that collects dependencies with their hashes and cache status. Add in the Caching section (around line 147):

```ocaml
type dep_info = {
  path: string;
  hash: string;
  module_name: string;
  in_cache: (string * string) option;  (* (cmo, cmi) paths if cached *)
}

let resolve_deps ~store_dir script_path =
  let sources = collect_deps script_path in
  let hash_map = Hashtbl.create 16 in
  List.map (fun src ->
    let module_name = module_name_of_path src in
    let module_base = String.uncapitalize_ascii module_name in
    let requires = extract_requires src in
    let dep_hashes =
      List.map (fun req ->
        let resolved = resolve_path ~relative_to:src req in
        Hashtbl.find hash_map resolved
      ) requires
    in
    let preprocessed = preprocess_to_string src in
    let hash = compute_hash ~dep_hashes ~preprocessed_content:preprocessed in
    Hashtbl.add hash_map src hash;
    let in_cache = find_in_cache ~store_dir ~hash ~module_name:module_base in
    { path = src; hash; module_name = module_base; in_cache }
  ) sources
```

### Step 2: Refactor `run` to use `resolve_deps`

Simplify the `run` function:

```ocaml
let run store_dir script_path args =
  let store_dir = match store_dir with Some d -> d | None -> default_store_dir () in
  let build_dir = Filename.temp_dir "mach" "" in
  let deps = resolve_deps ~store_dir script_path in
  let cmo_files =
    List.map (fun dep ->
      let cmo_in_build = Filename.(build_dir / dep.module_name ^ ".cmo") in
      let cmi_in_build = Filename.(build_dir / dep.module_name ^ ".cmi") in
      match dep.in_cache with
      | Some (cached_cmo, cached_cmi) ->
          copy_file cached_cmo cmo_in_build;
          copy_file cached_cmi cmi_in_build;
          cmo_in_build
      | None ->
          let preprocessed = preprocess_to_string dep.path in
          let output_ml = Filename.(build_dir / dep.module_name ^ ".ml") in
          write_file output_ml preprocessed;
          let cmd =
            Printf.sprintf "ocamlc -c -I %s -o %s %s"
              (Filename.quote build_dir)
              (Filename.quote cmo_in_build)
              (Filename.quote output_ml)
          in
          run_command cmd;
          store_in_cache ~store_dir ~hash:dep.hash ~module_name:dep.module_name ~build_dir;
          cmo_in_build
    ) deps
  in
  let exe_path = Filename.(build_dir / "a.out") in
  link ~build_dir cmo_files exe_path;
  let argv = Array.of_list (exe_path :: args) in
  Unix.execv exe_path argv
```

### Step 3: Add `deps` command function

Simple function that uses `resolve_deps`:

```ocaml
let deps store_dir script_path =
  let store_dir = match store_dir with Some d -> d | None -> default_store_dir () in
  let deps = resolve_deps ~store_dir script_path in
  List.iter (fun dep ->
    let status = match dep.in_cache with Some _ -> "in-store" | None -> "not-in-store" in
    Printf.printf "%s %s %s\n" dep.path dep.hash status
  ) deps
```

### Step 4: Add Cmdliner command for deps

Add after `run_cmd` definition:

```ocaml
let deps_cmd =
  let open Cmdliner in
  let doc = "Print dependencies of an OCaml script with their hashes and cache status" in
  let info = Cmd.info "deps" ~doc in
  Cmd.v info Term.(const deps $ store_arg $ script_arg)
```

### Step 5: Register deps command in group

Modify the `cmd` definition to include `deps_cmd`:

```ocaml
let cmd =
  let doc = "Run OCaml scripts with automatic dependency resolution" in
  let info = Cmd.info "mach" ~doc in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group ~default info [run_cmd; deps_cmd; store_cleanup_cmd]
```

### Step 6: Add cram test

Create `test/test_deps.t`:

```
  $ cat << 'EOF' > lib.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

  $ cat << 'EOF' > main.ml
  > [%%require "./lib.ml"]
  > let () = Lib.greet "World"
  > EOF

  $ mach deps --store ./store ./main.ml | sed "s|$PWD|.|g"
  ./lib.ml * not-in-store (glob)
  ./main.ml * not-in-store (glob)

  $ mach run --store ./store ./main.ml
  Hello, World!

  $ mach deps --store ./store ./main.ml | sed "s|$PWD|.|g"
  ./lib.ml * in-store (glob)
  ./main.ml * in-store (glob)
```

## Testing

Run cram tests:

```bash
dune test
```

then if tests look good, promote the outputs:
```
dune test --auto-promote
```

## Summary

Refactoring approach that extracts shared logic into `resolve_deps`:

1. **`dep_info` type + `resolve_deps` function** (~20 lines) - shared logic for collecting deps with hashes and cache status
2. **Refactor `run`** (~25 lines) - simplified to use `resolve_deps`
3. **`deps` function** (~6 lines) - thin wrapper around `resolve_deps`
4. **Cmdliner command** (~4 lines)
5. **Command group update** (1 line)
6. **Cram test** (~15 lines)

This eliminates code duplication and ensures hash computation is consistent between `run` and `deps`.
