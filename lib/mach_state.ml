open! Mach_std
open Sexplib0.Sexp_conv

type file_stat = { mtime : int; size : int } [@@deriving sexp]

let equal_file_stat x y = x.mtime = y.mtime && x.size = y.size

type lib = { name : string; version : string } [@@deriving sexp]

type entry = {
  ml_path : string;
  mli_path : string option;
  ml_stat : file_stat;
  mli_stat : file_stat option;
  requires : string with_loc list;
  libs : lib with_loc list;
} [@@deriving sexp]

type header = {
  mach_executable_path : string;
  ocaml_version : string;
  ocamlfind_version : string option;
} [@@deriving sexp]

type t = { header : header; root : entry; entries : entry list } [@@deriving sexp]

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
    let content = In_channel.with_open_text path In_channel.input_all in
    let sexp = Parsexp.Single.parse_string_exn content in
    Some (t_of_sexp sexp)
  with _ -> None

let write path state =
  let sexp = sexp_of_t state in
  Out_channel.with_open_text path (fun oc ->
    output_string oc (Sexplib0.Sexp.to_string_hum sexp);
    output_char oc '\n')

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
        let requires, libs = Mach_module.extract_requires_exn entry.ml_path in
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
      let requires, libs = Mach_module.extract_requires_exn ml_path in
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
