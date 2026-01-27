open! Mach_std
open Printf

(* --- Parsing --- *)

let is_empty_line line = String.for_all (function ' ' | '\t' -> true | _ -> false) line
let is_shebang line = String.length line >= 2 && line.[0] = '#' && line.[1] = '!'
let is_directive line = String.length line >= 1 && line.[0] = '#'

let preprocess_source ~source_path oc ic =
  fprintf oc "# 1 %S\n" source_path;
  let rec loop in_header =
    match In_channel.input_line ic with
    | None -> ()
    | Some line when is_empty_line line -> Buffer.output_line oc line; loop in_header
    | Some line when in_header && is_directive line -> Buffer.output_line oc ""; loop true
    | Some line -> Buffer.output_line oc line; loop false
  in
  loop true

type require =
  | Require of string with_loc
  | Require_lib of string with_loc
  | Require_extlib of extlib with_loc
and extlib = { name : string; version : string }

let is_require_path s = String.contains s '/'

let resolve_require_path ~source_path ~line req =
  let base_path =
    if Filename.is_relative req
    then Filename.concat (Filename.dirname source_path) req
    else req
  in
  if Sys.file_exists base_path && Sys.is_directory base_path then
    if Sys.file_exists (Filename.concat base_path "Machlib") then
      try Require_lib {v=Unix.realpath base_path; filename=source_path; line}
      with Unix.Unix_error (err, _, _) ->
        Mach_error.user_errorf "%s:%d: %s: %s" source_path line req (Unix.error_message err)
    else
      Mach_error.user_errorf "%s:%d: %s: directory has no Machlib file" source_path line req
  else
  let candidates =
    match Filename.extension base_path with
    | ".ml" | ".mlx" -> [base_path]
    | "" -> [base_path; base_path ^ ".ml"; base_path ^ ".mlx"]
    | ext -> Mach_error.user_errorf "%s:%d: %s: invalid file extension %S" source_path line req ext
  in
  let rec find_file = function
    | [] ->
        Mach_error.user_errorf "%s:%d: %s: No such file or directory" source_path line req
    | candidate :: rest ->
        if Sys.file_exists candidate then
          try Require {v=Unix.realpath candidate; filename=source_path; line}
          with Unix.Unix_error (err, _, _) ->
            Mach_error.user_errorf "%s:%d: %s: %s" source_path line req (Unix.error_message err)
        else
          find_file rest
  in
  find_file candidates

let resolve_require config ~source_path ~line req =
  if is_require_path req
  then resolve_require_path ~source_path ~line req
  else
    let info = Lazy.force config.Mach_config.toolchain.ocamlfind in
    if info.ocamlfind_version = None then
      Mach_error.user_errorf "%s:%d: library %S requires ocamlfind but ocamlfind is not installed" source_path line req
    else match SM.find_opt req info.ocamlfind_libs with
    | None ->
      Mach_error.user_errorf "%s:%d: library %S not found" source_path line req
    | Some version ->
      Require_extlib { v = { name = req; version }; filename = source_path; line }

let equal_require a b =
  match a, b with
  | Require a, Require b -> equal_without_loc a b
  | Require_lib a, Require_lib b -> equal_without_loc a b
  | Require_extlib a, Require_extlib b ->
    a.v.name = b.v.name && a.v.version = b.v.version
  | _ -> false

let extract_requires_exn config source_path =
  let rec parse line_num acc ic =
    match In_channel.input_line ic with
    | Some line when is_shebang line -> parse (line_num + 1) acc ic
    | Some line when is_directive line ->
      let req =
        try Scanf.sscanf line "#require %S%_s" Fun.id
        with Scanf.Scan_failure _ | End_of_file -> Mach_error.user_errorf "%s:%d: invalid #require directive" source_path line_num
      in
      let r = resolve_require config ~source_path ~line:line_num req in
      parse (line_num + 1) (r :: acc) ic
    | Some line when is_empty_line line -> parse (line_num + 1) acc ic
    | None | Some _ -> List.rev acc
  in
  In_channel.with_open_text source_path (parse 1 [])

type t = {
  path_ml : string;
  path_ml_stat : file_stat;
  path_mli : string option;
  path_mli_stat : file_stat option;
  requires : require list lazy_t;
  kind : kind;
}

and kind = ML | MLX

let kind_of_path_ml path =
  if Filename.extension path = ".mlx" then MLX else ML

let path_mli path_ml =
  let base = Filename.remove_extension path_ml in
  let mli = base ^ ".mli" in
  match file_stat mli with
  | None -> None, None
  | Some stat -> Some mli, Some stat

let of_path_exn config path_ml =
  let path_ml_stat = file_stat_exn path_ml in
  let path_mli, path_mli_stat = path_mli path_ml in
  let kind = kind_of_path_ml path_ml in
  let requires = lazy (extract_requires_exn config path_ml) in
  { path_ml; path_ml_stat; path_mli; path_mli_stat; requires; kind }

let of_path config path_ml =
  try Ok (of_path_exn config path_ml)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)

let path_mli path_ml = fst (path_mli path_ml)

let module_name_of_path path = Filename.(basename path |> remove_extension)

let cmx config m =
  Filename.(Mach_config.build_dir_of config m.path_ml / (module_name_of_path m.path_ml ^ ".cmx"))

let extlibs lib =
  List.filter_map (function
    | Require_extlib r -> Some r.v.name
    | _ -> None) !!(lib.requires) |> SS.of_list
