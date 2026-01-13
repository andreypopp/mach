open Printf

type file_stat = { mtime : int; size : int }

let equal_file_stat x y = x.mtime = y.mtime && x.size = y.size

type entry = {
  ml_path : string;
  mli_path : string option;
  ml_stat : file_stat;
  mli_stat : file_stat option;
  requires : string list;
  libs : string list;
}

type header = { build_backend : Mach_config.build_backend; mach_executable_path : string }

type t = { header : header; root : entry; entries : entry list }

let output_line oc line = output_string oc line; output_char oc '\n'

let mli_path_of_ml_if_exists path =
  let base = Filename.remove_extension path in
  let mli = base ^ ".mli" in
  if Sys.file_exists mli then Some mli else None

let file_stat path =
  let st = Unix.stat path in
  { mtime = Int.of_float st.Unix.st_mtime; size = st.Unix.st_size }

(* --- Parsing --- *)

let is_empty_line line = String.for_all (function ' ' | '\t' -> true | _ -> false) line
let is_shebang line = String.length line >= 2 && line.[0] = '#' && line.[1] = '!'
let is_directive line = String.length line >= 1 && line.[0] = '#'

let is_require_path s =
  String.length s > 0 && (
    String.starts_with ~prefix:"/" s ||
    String.starts_with ~prefix:"./" s ||
    String.starts_with ~prefix:"../" s)

let resolve_require ~source_path ~line path =
  let path =
    if Filename.is_relative path
    then Filename.concat (Filename.dirname source_path) path
    else path
  in
  try Unix.realpath path
  with Unix.Unix_error (err, _, _) ->
    Mach_error.user_errorf "%s:%d: %s: %s" source_path line path (Unix.error_message err)

let extract_requires_exn source_path : requires:string list * libs:string list =
  let rec parse line_num (~requires, ~libs) ic =
    match In_channel.input_line ic with
    | Some line when is_shebang line -> parse (line_num + 1) (~requires, ~libs) ic
    | Some line when is_directive line ->
      let req =
        try Scanf.sscanf line "#require %S%_s" Fun.id
        with Scanf.Scan_failure _ | End_of_file -> Mach_error.user_errorf "%s:%d: invalid #require directive" source_path line_num
      in
      if is_require_path req then
        let requires = resolve_require ~source_path ~line:line_num req::requires in
        parse (line_num + 1) (~requires, ~libs) ic
      else
        parse (line_num + 1) (~requires, ~libs:(req :: libs)) ic
    | Some line when is_empty_line line -> parse (line_num + 1) (~requires, ~libs) ic
    | None | Some _ -> ~requires:(List.rev requires), ~libs:(List.rev libs)
  in
  In_channel.with_open_text source_path (parse 1 (~requires:[], ~libs:[]))

let extract_requires source_path =
  try Ok (extract_requires_exn source_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)

(* --- State functions --- *)

let exe_path config t = Filename.concat (Mach_config.build_dir_of config t.root.ml_path) "a.out"

let source_dirs state =
  let seen = Hashtbl.create 16 in
  let add_dir path = Hashtbl.replace seen (Filename.dirname path) () in
  List.iter (fun entry -> add_dir entry.ml_path) state.entries;
  Hashtbl.fold (fun dir () acc -> dir :: acc) seen []
  |> List.sort String.compare

let all_libs state =
  let seen = Hashtbl.create 16 in
  let libs = ref [] in
  List.iter (fun entry ->
    List.iter (fun lib ->
      if not (Hashtbl.mem seen lib) then begin
        Hashtbl.add seen lib ();
        libs := lib :: !libs
      end
    ) entry.libs
  ) state.entries;
  List.rev !libs

let read path =
  if not (Sys.file_exists path) then None
  else try
    let lines = In_channel.with_open_text path In_channel.input_lines in
    (* Parse header *)
    let header, entry_lines = match lines with
      | bb_line :: mp_line :: "" :: rest ->
        let build_backend = Scanf.sscanf bb_line "build_backend %s" Mach_config.build_backend_of_string in
        let mach_executable_path = Scanf.sscanf mp_line "mach_executable_path %s@\n" Fun.id in
        Some { build_backend; mach_executable_path }, rest
      | _ -> None, []  (* Missing header = needs reconfigure *)
    in
    match header with
    | None -> None
    | Some header ->
      let mli_path_of ml_path =
        let base = Filename.remove_extension ml_path in
        Some (base ^ ".mli")
      in
      let finalize cur = {cur with requires = List.rev cur.requires; libs = List.rev cur.libs} in
      let rec loop acc cur = function
        | [] -> (match cur with Some cur -> finalize cur :: acc | None -> acc)
        | line :: rest when String.length line > 6 && String.sub line 0 6 = "  mli " ->
          let e = Option.get cur in
          let m, s = Scanf.sscanf line "  mli %i %d" (fun m s -> m, s) in
          loop acc (Some { e with mli_path = mli_path_of e.ml_path; mli_stat = Some { mtime = m; size = s } }) rest
        | line :: rest when String.length line > 6 && String.sub line 0 6 = "  lib " ->
          let e = Option.get cur in
          let lib = Scanf.sscanf line "  lib %s" Fun.id in
          loop acc (Some { e with libs = lib :: e.libs }) rest
        | line :: rest when String.length line > 2 && line.[0] = ' ' ->
          let e = Option.get cur in
          loop acc (Some { e with requires = Scanf.sscanf line "  requires %s" Fun.id :: e.requires }) rest
        | line :: rest ->
          let acc = match cur with Some cur -> finalize cur :: acc | None -> acc in
          let p, m, s = Scanf.sscanf line "%s %i %d" (fun p m s -> p, m, s) in
          loop acc (Some { ml_path = p; mli_path = None; ml_stat = { mtime = m; size = s }; mli_stat = None; requires = []; libs = [] }) rest
      in
      match loop [] None entry_lines with
      | [] -> None
      | root::_ as entries -> Some { header; root; entries = List.rev entries }
  with _ -> None

let write path state =
  Out_channel.with_open_text path (fun oc ->
    (* Write header *)
    output_line oc (sprintf "build_backend %s" (Mach_config.build_backend_to_string state.header.build_backend));
    output_line oc (sprintf "mach_executable_path %s" state.header.mach_executable_path);
    output_line oc "";
    (* Write entries *)
    List.iter (fun e ->
      output_line oc (sprintf "%s %i %d" e.ml_path e.ml_stat.mtime e.ml_stat.size);
      Option.iter (fun st -> output_line oc (sprintf "  mli %i %d" st.mtime st.size)) e.mli_stat;
      List.iter (fun r -> output_line oc (sprintf "  requires %s" r)) e.requires;
      List.iter (fun l -> output_line oc (sprintf "  lib %s" l)) e.libs
    ) state.entries)

let needs_reconfigure_exn config state =
  let build_backend = config.Mach_config.build_backend in
  let mach_path = config.Mach_config.mach_executable_path in
  if state.header.build_backend <> build_backend then
    (Mach_log.log_very_verbose "mach:state: build backend changed, need reconfigure"; true)
  else if state.header.mach_executable_path <> mach_path then
    (Mach_log.log_very_verbose "mach:state: mach path changed, need reconfigure"; true)
  else
    List.exists (fun entry ->
      if not (Sys.file_exists entry.ml_path)
      then (Mach_log.log_very_verbose "mach:state: file removed, need reconfigure"; true)
      else
        if mli_path_of_ml_if_exists entry.ml_path <> entry.mli_path
        then (Mach_log.log_very_verbose "mach:state: .mli added/removed, need reconfigure"; true)
        else
          if not (equal_file_stat (file_stat entry.ml_path) entry.ml_stat)
          then
            let ~requires, ~libs = extract_requires_exn entry.ml_path in
            if requires <> entry.requires || libs <> entry.libs
            then (Mach_log.log_very_verbose "mach:state: requires/libs changed, need reconfigure"; true)
            else false
          else false
    ) state.entries

let collect_exn config entry_path =
  let build_backend = config.Mach_config.build_backend in
  let mach_executable_path = config.Mach_config.mach_executable_path in
  let entry_path = Unix.realpath entry_path in
  let header = { build_backend; mach_executable_path } in
  let visited = Hashtbl.create 16 in
  let entries = ref [] in
  let rec dfs ml_path =
    if Hashtbl.mem visited ml_path then ()
    else begin
      Hashtbl.add visited ml_path ();
      let ~requires, ~libs = extract_requires_exn ml_path in
      List.iter dfs requires;
      let mli_path = mli_path_of_ml_if_exists ml_path in
      let mli_stat = Option.map file_stat mli_path in
      entries := { ml_path; mli_path; ml_stat = file_stat ml_path; mli_stat; requires; libs } :: !entries
    end
  in
  dfs entry_path;
  match !entries with
  | [] -> failwith "Internal error: no entries collected"
  | root::_ as entries -> { header; root; entries = List.rev entries }

let collect config entry_path =
  try Ok (collect_exn config entry_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
