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

let is_require_path s = String.contains s '/'

let resolve_require ~source_path ~line path =
  let base_path =
    if Filename.is_relative path
    then Filename.concat (Filename.dirname source_path) path
    else path
  in
  let candidates = [base_path ^ ".ml"; base_path ^ ".mlx"] in
  let rec find_file = function
    | [] ->
        Mach_error.user_errorf "%s:%d: %s: No such file or directory" source_path line path
    | candidate :: rest ->
        if Sys.file_exists candidate then
          try Unix.realpath candidate
          with Unix.Unix_error (err, _, _) ->
            Mach_error.user_errorf "%s:%d: %s: %s" source_path line path (Unix.error_message err)
        else
          find_file rest
  in
  find_file candidates

let extract_requires_exn source_path : requires:string with_loc list * libs:string with_loc list =
  let rec parse line_num (~requires, ~libs) ic =
    match In_channel.input_line ic with
    | Some line when is_shebang line -> parse (line_num + 1) (~requires, ~libs) ic
    | Some line when is_directive line ->
      let req =
        try Scanf.sscanf line "#require %S%_s" Fun.id
        with Scanf.Scan_failure _ | End_of_file -> Mach_error.user_errorf "%s:%d: invalid #require directive" source_path line_num
      in
      if is_require_path req then
        let resolved = resolve_require ~source_path ~line:line_num req in
        let requires = { v = resolved; filename = source_path; line = line_num } :: requires in
        parse (line_num + 1) (~requires, ~libs) ic
      else
        let lib = { v = req; filename = source_path; line = line_num } in
        parse (line_num + 1) (~requires, ~libs:(lib :: libs)) ic
    | Some line when is_empty_line line -> parse (line_num + 1) (~requires, ~libs) ic
    | None | Some _ -> ~requires:(List.rev requires), ~libs:(List.rev libs)
  in
  In_channel.with_open_text source_path (parse 1 (~requires:[], ~libs:[]))

let extract_requires source_path =
  try Ok (extract_requires_exn source_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
