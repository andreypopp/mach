open! Mach_std
open Printf

type file_stat = { mtime : int; size : int }

let equal_file_stat x y = x.mtime = y.mtime && x.size = y.size

type lib = { name : string; version : string }

type entry = {
  ml_path : string;
  mli_path : string option;
  ml_stat : file_stat;
  mli_stat : file_stat option;
  requires : string with_loc list;
  libs : lib with_loc list;
}

type header = {
  mach_executable_path : string;
  ocaml_version : string;
  ocamlfind_version : string option;
}

type t = { header : header; root : entry; entries : entry list }

let output_line oc line = output_string oc line; output_char oc '\n'

let mli_path_of_ml_if_exists path =
  let base = Filename.remove_extension path in
  let mli = base ^ ".mli" in
  if Sys.file_exists mli then Some mli else None

let file_stat path =
  let st = Unix.stat path in
  { mtime = Int.of_float st.Unix.st_mtime; size = st.Unix.st_size }

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
  List.iter (fun e -> List.iter (fun (l : lib with_loc) -> Hashtbl.replace seen l.v.name ()) e.libs) state.entries;
  Hashtbl.fold (fun l () acc -> l :: acc) seen [] |> List.sort String.compare

let read path =
  if not (Sys.file_exists path) then None
  else try
    let lines = In_channel.with_open_text path In_channel.input_lines in
    (* Parse header *)
    let header, entry_lines = match lines with
      | mp_line :: ov_line :: ofv_line :: "" :: rest ->
        let mach_executable_path = Scanf.sscanf mp_line "mach_executable_path %s@\n" Fun.id in
        let ocaml_version = Scanf.sscanf ov_line "ocaml_version %s@\n" Fun.id in
        let ocamlfind_version =
          let v = Scanf.sscanf ofv_line "ocamlfind_version %s@\n" Fun.id in
          if v = "none" then None else Some v
        in
        Some { mach_executable_path; ocaml_version; ocamlfind_version }, rest
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
          let filename, line_num, name, version = Scanf.sscanf line "  lib %s %d %s %s@\n" (fun f l n v -> f, l, n, v) in
          let lib : _ with_loc = { filename; line = line_num; v = { name; version } } in
          loop acc (Some { e with libs = lib :: e.libs }) rest
        | line :: rest when String.length line > 10 && String.sub line 0 10 = "  requires" ->
          let e = Option.get cur in
          let filename, line_num, v = Scanf.sscanf line "  requires %s %d %s" (fun f l v -> f, l, v) in
          let req : _ with_loc = { filename; line = line_num; v } in
          loop acc (Some { e with requires = req :: e.requires }) rest
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
    output_line oc (sprintf "mach_executable_path %s" state.header.mach_executable_path);
    output_line oc (sprintf "ocaml_version %s" state.header.ocaml_version);
    output_line oc (sprintf "ocamlfind_version %s" (Option.value state.header.ocamlfind_version ~default:"none"));
    output_line oc "";
    (* Write entries *)
    List.iter (fun e ->
      output_line oc (sprintf "%s %i %d" e.ml_path e.ml_stat.mtime e.ml_stat.size);
      Option.iter (fun st -> output_line oc (sprintf "  mli %i %d" st.mtime st.size)) e.mli_stat;
      List.iter (fun (r : _ with_loc) -> output_line oc (sprintf "  requires %s %d %s" r.filename r.line r.v)) e.requires;
      List.iter (fun (l : lib with_loc) -> output_line oc (sprintf "  lib %s %d %s %s" l.filename l.line l.v.name l.v.version)) e.libs
    ) state.entries)

type reconfigure_reason =
  | Env_changed
  | Modules_changed of SS.t

let check_reconfigure_exn config state =
  let mach_path = config.Mach_config.mach_executable_path in
  let toolchain = config.Mach_config.toolchain in
  (* Check environment first - if changed, need full reconfigure *)
  let env_changed =
    state.header.mach_executable_path <> mach_path ||
    state.header.ocaml_version <> toolchain.ocaml_version ||
    (state.header.ocamlfind_version <> None &&
     state.header.ocamlfind_version <> (Lazy.force toolchain.ocamlfind).ocamlfind_version)
  in
  if env_changed then
    (Mach_log.log_very_verbose "mach:state: environment changed, need reconfigure";
     Some Env_changed)
  else
    (* Check each entry for changes *)
    let changed_modules = SS.of_list @@ List.filter_map (fun entry ->
      if not (Sys.file_exists entry.ml_path) then None  (* removed files handled by collect_exn *)
      else if mli_path_of_ml_if_exists entry.ml_path <> entry.mli_path
      then (Mach_log.log_very_verbose "mach:state: .mli added/removed, need reconfigure";
            Some entry.ml_path)
      else if not (equal_file_stat (file_stat entry.ml_path) entry.ml_stat)
      then
        let ~requires, ~libs = Mach_module.extract_requires_exn entry.ml_path in
        let libs_names_equal =
          List.length libs = List.length entry.libs &&
          List.for_all2 (fun a b -> a.v = b.v.name && a.filename = b.filename && a.line = b.line)
            libs entry.libs
        in
        if not (List.equal equal_without_loc requires entry.requires) || not libs_names_equal
        then (Mach_log.log_very_verbose "mach:state: requires/libs changed, need reconfigure";
              Some entry.ml_path)
        else None
      else None
    ) state.entries in
    if SS.is_empty changed_modules then None
    else Some (Modules_changed changed_modules)

let collect_exn config entry_path =
  let mach_executable_path = config.Mach_config.mach_executable_path in
  let toolchain = config.Mach_config.toolchain in
  let entry_path = Unix.realpath entry_path in
  let visited = Hashtbl.create 16 in
  let entries = ref [] in
  let rec dfs ml_path =
    if Hashtbl.mem visited ml_path then ()
    else begin
      Hashtbl.add visited ml_path ();
      let ~requires, ~libs = Mach_module.extract_requires_exn ml_path in
      let libs = List.map (fun lib ->
        let info = Lazy.force toolchain.ocamlfind in
        if info.ocamlfind_version = None then
          Mach_error.user_errorf "%s:%d: library %S requires ocamlfind but ocamlfind is not installed" lib.filename lib.line lib.v
        else match SM.find_opt lib.v info.ocamlfind_libs with
        | None ->
          Mach_error.user_errorf "%s:%d: library %S not found" lib.filename lib.line lib.v
        | Some version ->
          { lib with v = { name = lib.v; version } }
      ) libs in
      List.iter (fun r -> dfs r.v) requires;
      let mli_path = mli_path_of_ml_if_exists ml_path in
      let mli_stat = Option.map file_stat mli_path in
      entries := { ml_path; mli_path; ml_stat = file_stat ml_path; mli_stat; requires; libs } :: !entries
    end
  in
  dfs entry_path;
  (* Lazy.is_val checks if lazy was forced, i.e. if any libs were encountered *)
  let ocamlfind_version =
    if Lazy.is_val toolchain.ocamlfind
    then (Lazy.force toolchain.ocamlfind).ocamlfind_version
    else None
  in
  let header = {
    mach_executable_path;
    ocaml_version = toolchain.ocaml_version;
    ocamlfind_version;
  } in
  match !entries with
  | [] -> failwith "Internal error: no entries collected"
  | root::_ as entries -> { header; root; entries = List.rev entries }

let collect config entry_path =
  try Ok (collect_exn config entry_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
