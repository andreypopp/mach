open! Mach_std
open Sexplib0.Sexp_conv

type file_stat = { mtime : int; size : int } [@@deriving sexp]

let equal_file_stat x y = x.mtime = y.mtime && x.size = y.size

type mach_lib_mod = Mach_library.lib_module = {
  file_ml : string;
  file_mli : string option;
} [@@deriving sexp]

type extlib = Mach_module.extlib = { name : string; version : string } [@@deriving sexp]

type require = Mach_module.require = 
  | Require of string with_loc
  | Require_lib of string with_loc
  | Require_extlib of extlib with_loc
  [@@deriving sexp]

type requires = require list [@@deriving sexp]

let equal_requires x y =
  try List.for_all2 Mach_module.equal_require x y
  with Invalid_argument _ -> false


type mach_mod = {
  path_ml : string;
  path_mli : string option;
  stat_ml : file_stat;
  stat_mli : file_stat option;
  requires : require list;
} [@@deriving sexp]

type mach_lib = {
  path : string;
  stat : file_stat;
  machlib_stat : file_stat;
  modules : mach_lib_mod list;
  requires : require list;
} [@@deriving sexp]

type mach_unit =
  | Unit_module of mach_mod
  | Unit_lib of mach_lib
[@@deriving sexp]

type t = {
  mach_executable_path : string;
  ocaml_version : string;
  ocamlfind_version : string option;
  units : mach_unit list;
} [@@deriving sexp]

let mli_path_of_ml_if_exists path =
  let base = Filename.remove_extension path in
  let mli = base ^ ".mli" in
  if Sys.file_exists mli then Some mli else None

let file_stat path =
  try
    let st = Unix.stat path in
    { mtime = Int.of_float st.Unix.st_mtime; size = st.Unix.st_size }
  with Unix.Unix_error (_, _, _) -> { mtime = 0; size = 0 }

(* --- State functions --- *)

let source_dirs state =
  let seen = Hashtbl.create 16 in
  List.iter (function
    | Unit_module m -> Hashtbl.replace seen (Filename.dirname m.path_ml) ()
    | Unit_lib l -> Hashtbl.replace seen l.path ()
  ) state.units;
  Hashtbl.fold (fun dir () acc -> dir :: acc) seen []
  |> List.sort String.compare

let libs state =
  List.filter_map (function
    | Unit_lib { path; machlib_stat; stat; modules; requires } -> 
      Some {Mach_library.path = path; modules = lazy modules; requires = lazy requires }
    | Unit_module _ -> None
  ) state.units
  |> List.sort (fun x y -> String.compare x.Mach_library.path y.Mach_library.path)

let modules state =
  List.filter_map (function
    | Unit_lib _ -> None
    | Unit_module m ->
      let kind = Mach_module.kind_of_path_ml m.path_ml in
      Some {Mach_module.path_ml = m.path_ml; path_mli = m.path_mli; requires = m.requires; kind }
  ) state.units

let extlibs state =
  let seen = Hashtbl.create 16 in
  let add_from_requires requires =
    List.iter (function
      | Mach_module.Require_extlib l -> Hashtbl.replace seen l.v.name ()
      | Mach_module.Require _ | Mach_module.Require_lib _ -> ()
    ) requires
  in
  List.iter (function
    | Unit_module m -> add_from_requires m.requires
    | Unit_lib l -> add_from_requires l.requires
  ) state.units;
  Hashtbl.fold (fun l () acc -> l :: acc) seen [] |> List.sort String.compare

let read path =
  if not (Sys.file_exists path) then None
  else try
    let content = In_channel.with_open_text path In_channel.input_all in
    let sexp = Parsexp.Single.parse_string_exn content in
    Some (t_of_sexp sexp)
  with _ -> None

let write path state =
  let tmp = path ^ ".tmp" in
  if Sys.file_exists tmp then Sys.remove tmp;
  Out_channel.with_open_text tmp (fun oc ->
    output_string oc (Sexplib0.Sexp.to_string_hum (sexp_of_t state));
    output_char oc '\n');
  Sys.rename tmp path

type reconfigure_reason =
  | Env_changed
  | Paths_changed of SS.t

let check_reconfigure_exn config state =
  let mach_path = config.Mach_config.mach_executable_path in
  let toolchain = config.Mach_config.toolchain in
  (* Check environment first - if changed, need full reconfigure *)
  let env_changed =
    state.mach_executable_path <> mach_path ||
    state.ocaml_version <> toolchain.ocaml_version ||
    (state.ocamlfind_version <> None &&
     state.ocamlfind_version <> (Lazy.force toolchain.ocamlfind).ocamlfind_version)
  in
  if env_changed then
    (Mach_log.log_very_verbose "mach:state: environment changed, need reconfigure";
     Some Env_changed)
  else
    let changed_because msg path =
      Mach_log.log_very_verbose "mach:state:%s:%s" path msg;
      Some path
    in
    let changed = SS.of_list @@ List.filter_map (function
      | Unit_module m ->
        if not (Sys.file_exists m.path_ml)
        then None (* removed files handled by collect_exn *)
        else if mli_path_of_ml_if_exists m.path_ml <> m.path_mli
        then changed_because "mli presence changed" m.path_ml
        else if
          not (equal_file_stat (file_stat m.path_ml) m.stat_ml)
          && not (equal_requires (Mach_module.of_path_exn config m.path_ml).requires m.requires)
        then changed_because "module requires changed" m.path_ml
        else None
      | Unit_lib l ->
        let machlib_path = Filename.(l.path / "Machlib") in
        let dir_changed = not (equal_file_stat (file_stat l.path) l.stat) in
        let machlib_changed = not (equal_file_stat (file_stat machlib_path) l.machlib_stat) in
        if machlib_changed then changed_because "Machlib file changed" l.path
        else if dir_changed then 
          let lib = Mach_library.of_path config l.path in
          if not (List.equal Mach_library.equal_lib_module !!(lib.modules) l.modules)
          then changed_because "library directory changed" l.path
          else None
        else None
    ) state.units in
    if SS.is_empty changed then None
    else Some (Paths_changed changed)

let collect_exn config entry_path =
  let mach_executable_path = config.Mach_config.mach_executable_path in
  let toolchain = config.Mach_config.toolchain in
  let entry_path = Unix.realpath entry_path in
  let visited = Hashtbl.create 16 in
  let units = ref [] in

  let rec dfs_module path =
    if Hashtbl.mem visited path then ()
    else begin
      Hashtbl.add visited path ();
      let m = Mach_module.of_path_exn config path in
      List.iter (function
        | Mach_module.Require r -> dfs_module r.v
        | Mach_module.Require_lib r -> dfs_library r.v
        | Mach_module.Require_extlib _ -> ()
      ) m.requires;
      let stat_mli = Option.map file_stat m.path_mli in
      units := Unit_module { path_ml = path; path_mli=m.path_mli; stat_ml = file_stat path; stat_mli; requires=m.requires } :: !units
    end

  and dfs_library path =
    if Hashtbl.mem visited path then ()
    else begin
      Hashtbl.add visited path ();
      let lib = Mach_library.of_path config path in
      let requires = !!(lib.requires) in
      List.iter (function
        | Mach_module.Require r -> dfs_module r.v
        | Mach_module.Require_lib r -> dfs_library r.v
        | Mach_module.Require_extlib _ -> ()
      ) requires;
      units := Unit_lib {
        path;
        machlib_stat = file_stat Filename.(path / "Machlib");
        stat = file_stat path;
        modules = !!(lib.modules);
        requires;
      } :: !units
    end
  in

  begin match Mach_module.resolve_require config ~source_path:entry_path ~line:0 entry_path with
  | Mach_module.Require r -> dfs_module r.v
  | Mach_module.Require_lib r -> dfs_library r.v
  | Mach_module.Require_extlib _ -> assert false
  end;

  let ocamlfind_version =
    if Lazy.is_val toolchain.ocamlfind
    then (Lazy.force toolchain.ocamlfind).ocamlfind_version
    else None
  in
  let ocaml_version = toolchain.ocaml_version in
  let units = List.rev !units in
  { mach_executable_path; ocaml_version; ocamlfind_version; units }

let collect config entry_path =
  try Ok (collect_exn config entry_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
