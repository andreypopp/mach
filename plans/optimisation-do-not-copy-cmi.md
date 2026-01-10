# Plan: Optimisation - Do Not Copy .cmi to Build Dir

## Overview

Currently, when dependencies are found in the cache store, both `.cmo` and `.cmi` files are copied from the store to the build directory. This is unnecessary I/O overhead. Instead, we can reference the store paths directly using `-I` flags.

## Current Behavior (bin/main.ml:222-244)

```ocaml
let cmo_files =
  List.map (fun dep ->
    let cmo_in_build = Filename.(build_dir / dep.module_name ^ ".cmo") in
    let cmi_in_build = Filename.(build_dir / dep.module_name ^ ".cmi") in
    match dep.in_cache with
    | Some (cached_cmo, cached_cmi) ->
        copy_file cached_cmo cmo_in_build;  (* unnecessary copy *)
        copy_file cached_cmi cmi_in_build;  (* unnecessary copy *)
        cmo_in_build
    | None ->
        (* compilation... *)
  ) deps
```

**Problems:**
1. Every cached `.cmo` and `.cmi` file is copied to build directory
2. For large projects with many dependencies, this creates significant I/O overhead
3. The files already exist in the store - no need to duplicate them

## Proposed Solution

### Key Changes

1. **Compile directly to store** - for non-cached deps, compile in `store/<hash>/` directory instead of build_dir, eliminating the copy step
2. **Track include directories per module** - only immediate dependencies need `-I` paths (transitive deps' types are already embedded in immediate deps' `.cmi` files)
3. **Use `-args` file for includes** - since the command line can get long with many `-I` flags, write them to an `includes.args` file and pass via `ocamlc -args includes.args`
4. **Use store paths for linking** - all `.cmo` files come from store directories

### Implementation Steps

#### Step 1: Extend `dep_info` to include immediate dependencies

We need to know each module's immediate dependencies to determine which `-I` paths it needs:

```ocaml
type dep_info = {
  path: string;
  hash: string;
  module_name: string;
  in_cache: (string * string) option;
  requires: string list;  (* immediate dependency paths *)
}
```

Update `resolve_deps` to populate `requires` field.

#### Step 2: Build lookup map from source path to dep_info

```ocaml
(* Maps source path -> dep_info for looking up dependencies *)
let dep_map : (string, dep_info) Hashtbl.t = Hashtbl.create 16
```

All `.cmi` files live in store directories (either already cached or compiled there in this run).

#### Step 3: Write per-module `includes.args` file

For each module to compile, write an args file with only its immediate dependencies:

```ocaml
let write_includes_args ~build_dir ~store_dir ~dep_map ~requires =
  let args_file = Filename.(build_dir / "includes.args") in
  Out_channel.with_open_text args_file (fun oc ->
    (* Add immediate dependencies' store directories *)
    List.iter (fun req_path ->
      match Hashtbl.find_opt dep_map req_path with
      | Some dep ->
          let dir = Filename.(store_dir / dep.hash) in
          output_string oc "-I\n";
          output_string oc dir;
          output_char oc '\n'
      | None -> ()
    ) requires
  );
  args_file
```

#### Step 4: Compile directly to store

For non-cached modules, compile directly in `store/<hash>/`:

```ocaml
let compile_to_store ~store_dir ~hash ~module_name ~preprocessed ~args_file =
  let store_hash_dir = Filename.(store_dir / hash) |> ensure_dir_rec in
  let source_ml = Filename.(store_hash_dir / module_name ^ ".ml") in
  let output_cmo = Filename.(store_hash_dir / module_name ^ ".cmo") in
  write_file source_ml preprocessed;
  let cmd =
    Printf.sprintf "ocamlc -c -args %s -o %s %s"
      (Filename.quote args_file)
      (Filename.quote output_cmo)
      (Filename.quote source_ml)
  in
  run_command cmd;
  output_cmo
```

#### Step 5: Write `objects.args` for linking

Since `.cmo` paths can also get long (they're spread across multiple store directories), write them to a file:

```ocaml
let write_objects_args ~build_dir cmo_files =
  let args_file = Filename.(build_dir / "objects.args") in
  Out_channel.with_open_text args_file (fun oc ->
    List.iter (fun cmo ->
      output_string oc cmo;
      output_char oc '\n'
    ) cmo_files
  );
  args_file

let link ~objects_args output =
  let cmd =
    Printf.sprintf "ocamlc -o %s -args %s"
      (Filename.quote output)
      (Filename.quote objects_args)
  in
  run_command cmd
```

### Complete Modified `run` Function

```ocaml
let run store_dir build_dir_opt script_path args =
  let build_dir = match build_dir_opt with
    | Some dir ->
        if Sys.file_exists dir
        then failwith (Printf.sprintf "Build directory already exists: %s" dir)
        else ensure_dir_rec dir
    | None ->
        Filename.temp_dir "mach" ""
  in
  let deps = resolve_deps ~store_dir script_path in

  (* Build lookup map from source path -> dep_info *)
  let dep_map = Hashtbl.create 16 in
  List.iter (fun dep -> Hashtbl.add dep_map dep.path dep) deps;

  (* Helper to write includes.args for a module's immediate dependencies *)
  let write_includes_args requires =
    let args_file = Filename.(build_dir / "includes.args") in
    Out_channel.with_open_text args_file (fun oc ->
      List.iter (fun req_path ->
        match Hashtbl.find_opt dep_map req_path with
        | Some dep ->
            let dir = Filename.(store_dir / dep.hash) in
            output_string oc "-I\n";
            output_string oc dir;
            output_char oc '\n'
        | None -> assert false
      ) requires
    );
    args_file
  in

  (* Process each dependency in topological order *)
  let cmo_files =
    List.map (fun dep ->
      let store_hash_dir = Filename.(store_dir / dep.hash) in
      let cmo_path = Filename.(store_hash_dir / dep.module_name ^ ".cmo") in
      (match dep.in_cache with
      | Some _ -> ()  (* already compiled *)
      | None ->
          (* Write includes.args with only immediate deps *)
          let args_file = write_includes_args dep.requires in
          (* Compile directly to store *)
          let _ = ensure_dir_rec store_hash_dir in
          let source_ml = Filename.(store_hash_dir / dep.module_name ^ ".ml") in
          let preprocessed = preprocess_to_string dep.path in
          write_file source_ml preprocessed;
          let cmd =
            Printf.sprintf "ocamlc -c -args %s -o %s %s"
              (Filename.quote args_file)
              (Filename.quote cmo_path)
              (Filename.quote source_ml)
          in
          run_command cmd);
      cmo_path
    ) deps
  in

  (* Write objects.args and link *)
  let exe_path = Filename.(build_dir / "a.out") in
  let objects_args = Filename.(build_dir / "objects.args") in
  Out_channel.with_open_text objects_args (fun oc ->
    List.iter (fun cmo ->
      output_string oc cmo;
      output_char oc '\n'
    ) cmo_files
  );
  link ~objects_args exe_path;

  let argv = Array.of_list (exe_path :: args) in
  Unix.execv exe_path argv
```

### Changes to `link` Function

The `link` function takes an args file with `.cmo` paths:

```ocaml
let link ~objects_args output =
  let cmd =
    Printf.sprintf "ocamlc -o %s -args %s"
      (Filename.quote output)
      (Filename.quote objects_args)
  in
  run_command cmd
```

### Testing Strategy

1. **Clean store test**: Run a script with no cache - should work as before
2. **Warm cache test**: Run same script again - should use cached `.cmo` directly without copying
3. **Mixed test**: Modify one dependency, run again - should use cache for unchanged deps, compile changed one
4. **Debug with --build-dir**: Use `--build-dir` option to inspect the `includes.args` file content

```bash
# Test commands
dune build
mach store-cleanup
mach run test/fixtures/with_deps.ml  # cold cache
mach run test/fixtures/with_deps.ml  # warm cache

# Debug inspection
mach run --build-dir /tmp/mach-debug test/fixtures/with_deps.ml
cat /tmp/mach-debug/includes.args
cat /tmp/mach-debug/objects.args
```

### Edge Cases to Consider

1. **Empty dependencies**: Script with no `[%%require]` - should still work (empty includes.args)
2. **Very long include lists**: The `-args` file approach handles this naturally

### Benefits

1. **No file copying**: Compile directly to store, no copy step at all
2. **Faster builds**: Both cold and warm builds benefit from reduced I/O
3. **Cleaner build directory**: Only contains `includes.args`, `objects.args`, `a.out`
4. **Scalability**: `-args` files handle arbitrarily long argument lists
5. **Minimal includes**: Only immediate deps' directories are included, not transitive

## Summary of File Changes

**bin/main.ml:**
- Extend `dep_info` type to include `requires` field (immediate dependencies)
- Update `resolve_deps` to populate `requires`
- Compile directly to `store/<hash>/` instead of build_dir (remove `store_in_cache`)
- Build `dep_map` lookup table from `deps` list
- Write per-module `includes.args` file with only immediate deps' store directories
- Write `objects.args` file with `.cmo` paths for linking
- Update `link` function to use `-args objects.args`
- Build_dir now only contains: `includes.args`, `objects.args`, `a.out`
