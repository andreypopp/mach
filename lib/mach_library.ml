(* mach_library - Library support for mach *)

open! Mach_std
open Sexplib0.Sexp_conv
open Printf

type lib_module = {
  file_ml : string;
  file_mli : string option;
} [@@deriving sexp]

type t = {
  path : string;
  modules : lib_module list Lazy.t;
  requires : Mach_module.require list Lazy.t;
}

let equal_lib_module a b =
  a.file_ml = b.file_ml && a.file_mli = b.file_mli

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

let cmxa config lib =
  let build_dir = Mach_config.build_dir_of config lib.path in
  Filename.(build_dir / Filename.basename lib.path ^ ".cmxa")
