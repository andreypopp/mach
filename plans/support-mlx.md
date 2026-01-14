# Plan: Support .mlx Files

## Overview

`.mlx` is an OCaml dialect with JSX syntax. The `mlx-pp` preprocessor transforms `.mlx` to `.ml`. We need to:
1. Build `.mlx` files with `-pp mlx-pp`
2. Configure `mach-lsp` to use `ocamlmerlin-mlx` reader for `.mlx` files

Key insight: `mach pp` is line-based preprocessing that works unchanged for `.mlx` files. The build pipeline for `.mlx`:
1. `mach pp` strips `#require` directives → outputs `.mlx` (preserving JSX)
2. Compiler uses `-pp mlx-pp` to transform JSX to OCaml

## Implementation

### 1. Update lib/mach_lib.ml

Add module kind tracking and modify build rules:

```ocaml
(* Add near ocaml_module definition, around line 26 *)
type module_kind = ML | MLX

let module_kind_of_path path =
  if Filename.extension path = ".mlx" then MLX else ML

let src_ext_of_kind = function ML -> ".ml" | MLX -> ".mlx"

(* Add kind field to ocaml_module *)
type ocaml_module = {
  ml_path: string;
  mli_path: string option;
  cmx: string;
  cmi: string;
  cmt: string;
  module_name: string;
  build_dir: string;
  resolved_requires: string with_loc list;
  libs: string with_loc list;
  kind: module_kind;  (* NEW *)
}
```

Modify `configure_ocaml_module` to use correct source extension:

```ocaml
let configure_ocaml_module b (m : ocaml_module) =
  let src_ext = src_ext_of_kind m.kind in
  let src = Filename.(m.build_dir / m.module_name ^ src_ext) in
  let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
  B.rulef b ~target:src ~deps:[m.ml_path] "%s pp %s > %s" cmd m.ml_path src;
  (* rest unchanged, but use src instead of ml *)
```

Modify `compile_ocaml_module` to add `-pp mlx-pp` for MLX files:

```ocaml
let compile_ocaml_module b (m : ocaml_module) =
  let src_ext = src_ext_of_kind m.kind in
  let src = Filename.(m.build_dir / m.module_name ^ src_ext) in
  let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
  let args = Filename.(m.build_dir / "includes.args") in
  let pp_flag = match m.kind with ML -> "" | MLX -> " -pp mlx-pp" in
  let cmi_deps = List.map (fun (r : _ with_loc) -> Filename.(build_dir_of r.v / module_name_of_path r.v ^ ".cmi")) m.resolved_requires in
  let lib_args_dep, lib_args_cmd = match m.libs with
    | [] -> [], ""
    | _ -> [Filename.(m.build_dir / "lib_includes.args")], sprintf " -args %s" Filename.(m.build_dir / "lib_includes.args")
  in
  match m.mli_path with
  | Some _ ->
    B.rule b ~target:m.cmi ~deps:(mli :: args :: lib_args_dep @ cmi_deps)
      [capture_outf "ocamlc%s -bin-annot -c -opaque -args %s%s -o %s %s" pp_flag args lib_args_cmd m.cmi mli];
    B.rule b ~target:m.cmx ~deps:([src; m.cmi; args] @ lib_args_dep)
      [capture_outf "ocamlopt%s -bin-annot -c -args %s%s -cmi-file %s -o %s %s" pp_flag args lib_args_cmd m.cmi m.cmx src];
    B.rule b ~target:m.cmt ~deps:[m.cmx] []
  | None ->
    B.rule b ~target:m.cmx ~deps:(src :: args :: lib_args_dep @ cmi_deps)
      [capture_outf "ocamlopt%s -bin-annot -c -args %s%s -o %s %s" pp_flag args lib_args_cmd m.cmx src];
    B.rule b ~target:m.cmi ~deps:[m.cmx] [];
    B.rule b ~target:m.cmt ~deps:[m.cmx] []
```

Populate `kind` field when building modules list (around line 109):

```ocaml
let modules = List.map (fun ({ml_path;mli_path;requires=resolved_requires;libs;_} : Mach_state.entry) ->
  let module_name = module_name_of_path ml_path in
  let build_dir = build_dir_of ml_path in
  let kind = module_kind_of_path ml_path in  (* NEW *)
  let cmx = Filename.(build_dir / module_name ^ ".cmx") in
  let cmi = Filename.(build_dir / module_name ^ ".cmi") in
  let cmt = Filename.(build_dir / module_name ^ ".cmt") in
  { ml_path; mli_path; module_name; build_dir; resolved_requires; cmx; cmi; cmt; libs; kind }
) state.Mach_state.entries
```

Update `watch_exn` to watch `.mlx` files (line 275):

```ocaml
let cmd = sprintf "watchexec --debounce 200ms --only-emit-events --emit-events-to=stdio --stdin-quit -e ml,mli,mlx @%s" watchlist_path in
```

### 2. Update bin/mach_lsp.ml

Add `READER` directive for `.mlx` files in `directives_for_file`:

```ocaml
let directives_for_file path : Merlin_dot_protocol.directive list =
  try
    let path = Unix.realpath path in
    let is_mlx = Filename.extension path = ".mlx" in
    let config = match Mach_config.get () with
      | Ok config -> config
      | Error (`User_error msg) -> raise (Failure msg)
    in
    let build_dir = Mach_config.build_dir_of config path in
    match Mach_module.extract_requires path with
    | Error (`User_error msg) -> [`ERROR_MSG msg]
    | Ok (~requires, ~libs:_) ->
    let dep_dirs = parse_includes_args (Filename.concat build_dir "includes.args") in
    let lib_dirs = parse_includes_args (Filename.concat build_dir "lib_includes.args") in
    let directives = [] in
    (* Add READER for .mlx files *)
    let directives = if is_mlx then `READER ["ocamlmerlin-mlx"] :: directives else directives in
    let directives =
      if lib_dirs = [] then directives
      else
        let lib_flags = List.concat_map (fun p -> ["-I"; p]) lib_dirs in
        (`FLG lib_flags) :: directives
    in
    let directives =
      List.fold_left (fun directives (dep_dir : string) ->
        (`FLG ["-I"; dep_dir]) :: `CMT build_dir :: `B build_dir :: directives
      ) directives dep_dirs
    in
    let directives =
      List.fold_left (fun directives (require : _ Mach_std.with_loc) ->
        `S (Filename.dirname require.v)::directives
      ) directives requires
    in
    let directives = `S (Filename.dirname path) :: directives in
    `FLG ["-pp"; "mach pp"] :: directives
  with
  | Failure msg -> [`ERROR_MSG msg]
  | Unix.Unix_error (err, _, arg) ->
    [`ERROR_MSG (sprintf "%s: %s" (Unix.error_message err) arg)]
  | _ -> [`ERROR_MSG "Unknown error computing merlin config"]
```

### 3. Add test/test_mlx.t

```
Isolate mach config to a test dir:
  $ . ../env.sh

Check if mlx-pp is available, skip if not:
  $ command -v mlx-pp > /dev/null || exit 80

Test simple .mlx file:
  $ cat << 'EOF' > component.mlx
  > let element = <div>"Hello, MLX!"</div>
  > let () = print_endline "MLX works"
  > EOF

  $ mach run ./component.mlx
  MLX works

Test .mlx depending on .ml:
  $ cat << 'EOF' > helper.ml
  > let greet () = print_endline "Hello from ML"
  > EOF

  $ cat << 'EOF' > app.mlx
  > #require "./helper.ml"
  > let element = <div>"App"</div>
  > let () = Helper.greet ()
  > EOF

  $ mach run ./app.mlx
  Hello from ML

Test .ml depending on .mlx:
  $ cat << 'EOF' > widget.mlx
  > let render () = print_endline "Widget rendered"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./widget.mlx"
  > let () = Widget.render ()
  > EOF

  $ mach run ./main.ml
  Widget rendered
```
