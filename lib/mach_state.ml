open! Mach_std
open Sexplib0.Sexp_conv

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

type mach_module = Mach_module.t = {
  path_ml : string;
  path_ml_stat : file_stat;
  path_mli : string option;
  path_mli_stat : file_stat option;
  requires : require list lazy_t;
  kind : module_kind;
} [@@deriving sexp]

and module_kind = Mach_module.kind = ML | MLX [@@deriving sexp]

type mach_library = Mach_library.t = {
  path : string;
  path_stat : file_stat;
  machlib_stat : file_stat;
  modules : mach_lib_mod list lazy_t;
  requires : require list lazy_t;
} [@@deriving sexp]

type mach_unit =
  | Unit_module of mach_module
  | Unit_lib of mach_library
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

(* --- State functions --- *)

let write config state =
  let unit_path = match state.units with
    | [Unit_module m] -> m.path_ml
    | [Unit_lib l] -> l.path
    | _ -> failwith "mach_state: write: can only write state for a single unit"
  in
  let path = Filename.(Mach_config.build_dir_of config unit_path / "Mach.state") in
  let tmp = path ^ ".tmp" in
  if Sys.file_exists tmp then Sys.remove tmp;
  Out_channel.with_open_text tmp (fun oc ->
    output_string oc (Sexplib0.Sexp.to_string_hum (sexp_of_t state));
    output_char oc '\n');
  Sys.rename tmp path

type 'a unit_validation_error =
  | Invalid (** unit is invalid (missing files or etc), dependent units need to be reconfigured *)
  | Changed of 'a (** unit has changed, it needs to be reconfigured *)
  | Env_changed (** environment of the unit has changed, it needs to be reconfigured *)
  | No_state (** no state exists for the unit, it needs to be configured from scratch *)

type 'a unit_validation_result = ('a, 'a unit_validation_error) result

let validate_module config unit : Mach_module.t unit_validation_result =
  match unit with
  | Unit_module m ->
    begin match file_stat m.path_ml with
    | None -> Error Invalid
    | Some path_ml_stat ->
    if mli_path_of_ml_if_exists m.path_ml <> m.path_mli
    then Error (Changed (Mach_module.of_path_exn config m.path_ml))
    else if not (equal_file_stat path_ml_stat m.path_ml_stat)
    then
      let m' = Mach_module.of_path_exn config m.path_ml in
      if not (equal_requires !!(m'.requires) !!(m.requires))
      then Error (Changed m')
      else Ok m
    else Ok m
    end
  | _ -> Error Invalid

let validate_lib config unit : Mach_library.t unit_validation_result =
  match unit with
  | Unit_lib lib ->
    let machlib_path = Filename.(lib.path / "Machlib") in
    begin match file_stat lib.path with
    | None -> Error Invalid
    | Some path_stat ->
    match file_stat machlib_path with
    | None -> Error Invalid
    | Some machlib_stat ->
    let machlib_changed = not (equal_file_stat machlib_stat lib.machlib_stat) in
    if not (Sys.file_exists machlib_path) then Error Invalid else
    let dir_changed = not (equal_file_stat path_stat lib.path_stat) in
    if machlib_changed then Error (Changed (Mach_library.of_path config lib.path))
    else if dir_changed then 
      let lib' = Mach_library.of_path config lib.path in
      if not (List.equal Mach_library.equal_lib_module !!(lib'.modules) !!(lib.modules))
      then Error (Changed lib')
      else Ok lib
    else Ok lib
    end
  | _ -> Error Invalid

let env_changed config state =
  let mach_path = config.Mach_config.mach_executable_path in
  let toolchain = config.Mach_config.toolchain in
  state.mach_executable_path <> mach_path ||
  state.ocaml_version <> toolchain.ocaml_version ||
  (state.ocamlfind_version <> None &&
    state.ocamlfind_version <> (Lazy.force toolchain.ocamlfind).ocamlfind_version)

let read path =
  if not (Sys.file_exists path) then None
  else try
    let content = In_channel.with_open_text path In_channel.input_all in
    let sexp = Parsexp.Single.parse_string_exn content in
    Some (t_of_sexp sexp)
  with _ -> None

let read_mach_state config validate path =
  let filename = Filename.(Mach_config.build_dir_of config path / "Mach.state") in
  match read filename with
  | None -> Error No_state
  | Some state -> 
    if env_changed config state then Error Env_changed
    else 
      (* TODO: List.hd is temporary, need to change type def to allow a single unit per state. *)
      validate config (List.hd state.units)

type 'a with_state = { 
  unit: 'a;
  state: t;
  need_configure: bool;
}

let crawl config ~target_path =
  let exception Invalid_require in
  let if_not_visited =
    let visited = Hashtbl.create 16 in
    fun path f ->
      if Hashtbl.mem visited path then ()
      else begin
        Hashtbl.add visited path ();
        try f () with Invalid_require ->
          Hashtbl.remove visited path;
          raise_notrace Invalid_require
      end
  in
  let units = ref [] in
  let add_unit ~need_configure unit = units := (unit, need_configure) :: !units in
  let rec visit_module path =
    if_not_visited path @@ fun () ->
    match read_mach_state config validate_module path with
    | Ok m ->
      begin match List.iter visit_require !!(m.requires) with
      | () -> add_unit ~need_configure:false (Unit_module m)
      | exception Invalid_require -> parse_and_add_module path
      end
    | Error Changed m ->
      List.iter visit_require !!(m.requires);
      add_unit ~need_configure:true (Unit_module m)
    | Error Invalid -> raise_notrace Invalid_require
    | Error Env_changed | Error No_state -> parse_and_add_module path
  and parse_and_add_module path =
    let m = Mach_module.of_path_exn config path in
    List.iter visit_require !!(m.requires);
    add_unit ~need_configure:true (Unit_module m)
  and visit_library path =
    if_not_visited path @@ fun () ->
    match read_mach_state config validate_lib path with
    | Ok lib ->
      begin match List.iter visit_require !!(lib.requires) with
      | () -> add_unit ~need_configure:false (Unit_lib lib)
      | exception Invalid_require -> parse_and_add_library path
      end
    | Error Changed lib ->
      List.iter visit_require !!(lib.requires);
      add_unit ~need_configure:true (Unit_lib lib)
    | Error Invalid -> raise_notrace Invalid_require
    | Error Env_changed | Error No_state -> parse_and_add_library path
  and parse_and_add_library path =
    let lib = Mach_library.of_path config path in
    List.iter visit_require !!(lib.requires);
    add_unit ~need_configure:true (Unit_lib lib)
  and visit_require = function
    | Mach_module.Require r -> visit_module r.v
    | Mach_module.Require_lib r -> visit_library r.v
    | Mach_module.Require_extlib _ -> ()
  in
  visit_require
    (let targe_path = Unix.realpath target_path in
     Mach_module.resolve_require config ~source_path:targe_path ~line:0 targe_path);
  let toolchain = config.Mach_config.toolchain in
  let ocamlfind_version =
    if Lazy.is_val toolchain.ocamlfind
    then (Lazy.force toolchain.ocamlfind).ocamlfind_version
    else None
  in
  let ocaml_version = toolchain.ocaml_version in
  let mach_executable_path = config.Mach_config.mach_executable_path in
  List.rev_map (fun (unit, need_configure) ->
    let state = { mach_executable_path; ocaml_version; ocamlfind_version; units=[unit] } in
    match unit with
    | Unit_module unit -> Either.Left { unit; state; need_configure }
    | Unit_lib unit -> Right { unit; state; need_configure }) !units
