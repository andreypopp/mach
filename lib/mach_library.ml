(* mach_library - Library support for mach *)

open! Mach_std
open Sexplib0.Sexp_conv
open Printf

(* --- Types --- *)

type lib_module = {
  file_ml : string;        (* relative filename, e.g., "foo.ml" *)
  file_mli : string option; (* relative filename if exists *)
} [@@deriving sexp]

type t = {
  path : string;  (* absolute path to library directory *)
  modules : lib_module list Lazy.t;  (* modules in the library *)
  requires : Mach_module.require list Lazy.t;  (* resolved requires *)
}

let equal_lib_module a b =
  a.file_ml = b.file_ml && a.file_mli = b.file_mli

(* --- Machlib parsing --- *)

type machlib = Require of string list [@sexp.list] [@@deriving sexp]

let of_path config path =
  let machlib_path = Filename.concat path "Machlib" in
  let requires = lazy begin 
    let content = In_channel.(with_open_text machlib_path input_all) in
    let machlib =
      try 
        let sexp = Parsexp.Many.parse_string_exn content in
        List.map machlib_of_sexp sexp
      with
      | Parsexp.Parse_error e ->
        Mach_error.user_errorf "%s: parse error: %s" machlib_path (Parsexp.Parse_error.message e)
      | Sexplib0.Sexp_conv_error.Of_sexp_error (exn, _) ->
        Mach_error.user_errorf "%s: invalid format: %s" machlib_path (Printexc.to_string exn)
    in
    let line = 1 in (* TODO: get actual line numbers from sexp *)
    List.concat_map (fun (Require reqs) ->
      List.map (Mach_module.resolve_require config ~source_path:machlib_path ~line) reqs) machlib
  end in
  let modules = lazy (
    Sys.readdir path
    |> Array.to_list
    |> List.filter_map (fun file_ml ->
        let ext = Filename.extension file_ml in
        if ext = ".ml" || ext = ".mlx" then
          let file_mli = Option.map Filename.basename (Mach_module.path_mli Filename.(path / file_ml)) in
          Some { file_ml; file_mli }
        else None)
    |> List.sort (fun a b -> String.compare a.file_ml b.file_ml)) in
  { path; modules; requires }

(* --- Build configuration for libraries --- *)

let module_name_of_file file =
  String.capitalize_ascii (Filename.remove_extension file)

let configure_library config lib =
  let lib_path = lib.path in
  let lib_modules = lib.modules in
  let requires, libs = List.partition_map (function
    | Mach_module.Require r -> Left r
    | Mach_module.Require_lib r -> Left r
    | Mach_module.Require_extlib l -> Right l
  ) !!(lib.requires) in
  let build_dir = Mach_config.build_dir_of config lib_path in
  let lib_name = Filename.basename lib_path in
  let mach_cmd = config.Mach_config.mach_executable_path in
  let capture_outf fmt = ksprintf (sprintf "${MACH} run-build-command -- %s") fmt in
  let capture_stderrf fmt = ksprintf (sprintf "${MACH} run-build-command --stderr-only -- %s") fmt in

  mkdir_p build_dir;

  let b = Ninja.create () in
  Ninja.var b "MACH" mach_cmd;

  (* Generate includes.args for library's own build dir + external dependencies *)
  let args_file = Filename.concat build_dir "includes.args" in
  let () =
    let recipe =
      (* Always include the library's own build directory first *)
      sprintf "echo '-I=%s' > %s" build_dir args_file ::
      List.map (fun (r : _ with_loc) ->
        sprintf "echo '-I=%s' >> %s" (Mach_config.build_dir_of config r.v) args_file
      ) requires
    in
    Ninja.rule b ~target:args_file ~deps:[] recipe
  in

  (* Generate lib_includes.args if ocamlfind libs present *)
  let () = match libs with
    | [] -> ()
    | libs ->
      let lib_args = Filename.concat build_dir "lib_includes.args" in
      let lib_names = String.concat " " (List.map (fun (l : Mach_module.extlib with_loc) -> l.v.name) libs) in
      Ninja.rule b ~target:lib_args ~deps:[]
        [capture_stderrf "ocamlfind query -format '-I=%%d' -recursive %s > %s" lib_names lib_args]
  in

  let lib_args_dep, lib_args_cmd = match libs with
    | [] -> [], ""
    | _ ->
      let lib_args = Filename.concat build_dir "lib_includes.args" in
      [lib_args], sprintf " -args %s" lib_args
  in

  (* For each module in the library *)
  let all_deps = ref [] in
  List.iter (fun (m : lib_module) ->
    let base_name = Filename.remove_extension m.file_ml in
    let src_ml = Filename.concat lib_path m.file_ml in
    let build_ml = Filename.concat build_dir (base_name ^ ".ml") in
    let cmx = Filename.concat build_dir (base_name ^ ".cmx") in
    let cmi = Filename.concat build_dir (base_name ^ ".cmi") in
    let dep_file = Filename.concat build_dir (base_name ^ ".dep") in

    all_deps := (dep_file, cmx) :: !all_deps;

    (* Preprocess source with mach pp (inserts # directive for error reporting) *)
    let is_mlx = Filename.extension m.file_ml = ".mlx" in
    let pp_flag = if is_mlx then " --pp mlx-pp" else "" in
    Ninja.rulef b ~target:build_ml ~deps:[src_ml] "%s pp%s -o %s %s" mach_cmd pp_flag build_ml src_ml;

    (* Preprocess .mli if exists *)
    Option.iter (fun file_mli ->
      let src_mli = Filename.concat lib_path file_mli in
      let build_mli = Filename.concat build_dir (base_name ^ ".mli") in
      Ninja.rulef b ~target:build_mli ~deps:[src_mli] "%s pp -o %s %s" mach_cmd build_mli src_mli
    ) m.file_mli;

    (* Run ocamldep via mach dep to get dependencies *)
    Ninja.rulef b ~target:dep_file ~deps:[build_ml; args_file]
      "%s dep %s -o %s --args %s" mach_cmd build_ml dep_file args_file;

    (* Compile module with dyndep *)
    match m.file_mli with
    | Some _ ->
      let build_mli = Filename.concat build_dir (base_name ^ ".mli") in
      (* Compile .mli first *)
      Ninja.rule b ~target:cmi ~deps:([build_mli; args_file] @ lib_args_dep)
        [capture_outf "ocamlc -bin-annot -c -opaque -I %s -args %s%s -o %s %s"
          build_dir args_file lib_args_cmd cmi build_mli];
      (* Compile .ml with dyndep *)
      Ninja.rule b ~target:cmx ~deps:([build_ml; cmi; dep_file; args_file] @ lib_args_dep)
        ~dyndep:dep_file
        [capture_outf "ocamlopt -bin-annot -c -I %s -args %s%s -cmi-file %s -o %s -impl %s"
          build_dir args_file lib_args_cmd cmi cmx build_ml]
    | None ->
      (* Without .mli: compile with dyndep *)
      Ninja.rule b ~target:cmx ~deps:([build_ml; dep_file; args_file] @ lib_args_dep)
        ~dyndep:dep_file
        [capture_outf "ocamlopt -bin-annot -c -I %s -args %s%s -o %s -impl %s"
          build_dir args_file lib_args_cmd cmx build_ml];
      Ninja.rule b ~target:cmi ~deps:[cmx] []
  ) !!(lib_modules);

  (* Create archive - use mach link-deps to get correct order from .dep files *)
  let all_deps = List.rev !all_deps in
  let all_cmx = List.map snd all_deps in
  let dep_files = List.map fst all_deps in
  let link_deps_file = Filename.concat build_dir (lib_name ^ ".link-deps") in
  let cmxa = Filename.concat build_dir (lib_name ^ ".cmxa") in
  let cmxa_a = Filename.concat build_dir (lib_name ^ ".a") in
  Ninja.rulef b ~target:link_deps_file ~deps:dep_files
    "%s link-deps %s > %s" mach_cmd (String.concat " " dep_files) link_deps_file;
  Ninja.rule b ~target:cmxa ~deps:(link_deps_file :: all_cmx)
    [capture_outf "ocamlopt -a -o %s -args %s" cmxa link_deps_file];
  Ninja.rule b ~target:cmxa_a ~deps:[cmxa] [];

  (* Write ninja file *)
  let ninja_file = Filename.concat build_dir "mach.ninja" in
  write_file ninja_file (Ninja.contents b)

let cmxa config lib =
  let build_dir = Mach_config.build_dir_of config lib.path in
  Filename.(build_dir / Filename.basename lib.path ^ ".cmxa")
