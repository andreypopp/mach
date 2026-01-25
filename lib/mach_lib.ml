(* mach_lib - Shared code for mach and mach-lsp *)

open! Mach_std
open Printf

type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let log_verbose = Mach_log.log_verbose
let log_very_verbose = Mach_log.log_very_verbose

(* --- PP (for merlin and build) --- *)

let pp ~source_path ic oc =
  Mach_module.preprocess_source ~source_path oc ic

(* --- Configure --- *)

let configure_module ~build_dir ninja config (m : Mach_module.t) =
  let _includes_args = 
    let ml, _mli =
      Mach_ocaml_rules.preprocess_ocaml_module ninja config
        ~build_dir
        ~path_ml:m.path_ml
        ~path_mli:m.path_mli
        ~kind:m.kind
    in
    Mach_ocaml_rules.compile_ocaml_args ninja config
      ~requires:m.requires
      ~build_dir
      ~deps:[ml]
  in
  Mach_ocaml_rules.compile_ocaml_module ninja config
    ~path_ml:m.path_ml
    ~path_mli:m.path_mli
    ~requires:m.requires
    ~build_dir

let configure_library ~build_dir ninja config (lib : Mach_library.t) =
  let lib_name = Filename.basename lib.path in
  let includes_args =
    Mach_ocaml_rules.compile_ocaml_args ~include_self:true ninja config
      ~requires:!!(lib.requires)
      ~build_dir
      ~deps:[Filename.(lib.path / "Machlib")]
  in
  let deps, cmxs =
    List.map (fun (m : Mach_library.lib_module) ->
      let src_ml = Filename.(lib.path / m.file_ml) in
      let src_mli = Option.map (fun file_mli -> Filename.(lib.path / file_mli)) m.file_mli in
      let ml, mli =
        Mach_ocaml_rules.preprocess_ocaml_module ninja config
          ~build_dir
          ~path_ml:src_ml
          ~path_mli:src_mli
          ~kind:(Mach_module.kind_of_path_ml src_ml);
      in
      let path_dep = Mach_ocaml_rules.ocamldep ninja config
        ~build_dir
        ~path_ml:ml
        ~includes_args
      in
      let _cmi, cmx =
        Mach_ocaml_rules.compile_ocaml_module ninja config
          ~dyndep:path_dep
          ~build_dir
          ~path_ml:ml
          ~path_mli:mli
          ~requires:!!(lib.requires)
      in
      path_dep, cmx
    ) !!(lib.modules)
    |> List.split
  in
  Mach_ocaml_rules.link_ocaml_library ninja config
    ~build_dir
    ~cmxs
    ~deps
    ~lib_name

let configure_backend config ~state ~prev_state ~changed_paths script_path =
  let build_dir_of = Mach_config.build_dir_of config in
  let module_file = "mach.ninja" in
  let root_file = "build.ninja" in
  let cmd = config.Mach_config.mach_executable_path in
  let old_modules, old_libs = match prev_state with
    | None -> SS.empty, SS.empty
    | Some old ->
      let libs = Mach_state.libs old |> List.map (fun lib -> lib.Mach_library.path) in
      let modules = Mach_state.modules old |> List.map (fun lib -> lib.Mach_module.path_ml) in
      SS.of_list modules, SS.of_list libs
  in
  let modules = Mach_state.modules state in
  let modules =
    List.map (fun (m : Mach_module.t) ->
      let build_dir = build_dir_of m.path_ml in
      let needs_configure = match changed_paths with
        | None -> true  (* full reconfigure *)
        | Some changed_paths -> SS.mem m.path_ml changed_paths || not (SS.mem m.path_ml old_modules)
      in
      if needs_configure then begin
        log_verbose "mach: configuring %s" m.path_ml;
        mkdir_p build_dir;
        let b = Ninja.create () in
        let _cmi, cmx = configure_module ~build_dir b config m in
        write_file Filename.(build_dir / module_file) (Ninja.contents b);
        m, cmx
      end
      else m, Mach_module.cmx config m
    ) modules
  in
  let libs = Mach_state.libs state in
  List.iter (fun (lib : Mach_library.t) ->
    let needs_configure = match changed_paths with
      | None -> true  (* full reconfigure *)
      | Some changed -> SS.mem lib.path changed || not (SS.mem lib.path old_libs)
    in
    if needs_configure then begin
      log_verbose "mach: configuring library %s" lib.path;
      let build_dir = Mach_config.build_dir_of config lib.path in
      let mach_cmd = config.Mach_config.mach_executable_path in
      mkdir_p build_dir;
      let b = Ninja.create () in
      Ninja.var b "MACH" mach_cmd;
      configure_library b config lib ~build_dir;
      write_file Filename.(build_dir / "mach.ninja") (Ninja.contents b)
    end
  ) libs;
  (* Generate root build file *)
  let exe_path = Filename.(build_dir_of script_path / "a.out") in
  let cmxs = List.map snd modules in
  let extlibs = Mach_state.extlibs state in
  write_file Filename.(build_dir_of script_path / root_file) (
    log_verbose "mach: configuring %s (root)" script_path;
    let b = Ninja.create () in
    Ninja.var b "MACH" cmd;
    List.iter (fun lib -> Ninja.subninja b Filename.(build_dir_of lib.Mach_library.path / module_file)) libs;
    List.iter (fun (m, _cmx) -> Ninja.subninja b Filename.(build_dir_of m.Mach_module.path_ml / module_file)) modules;
    Ninja.rule_phony b ~target:"all" ~deps:[exe_path];
    let cmxas = List.map (Mach_library.cmxa config) libs in
    Mach_ocaml_rules.link_ocaml_executable b config
      ~exe_path
      ~extlibs
      ~cmxs
      ~cmxas
      ~build_dir:(build_dir_of script_path);
    Ninja.contents b
  )

let configure_exn config source_path =
  let source_path = Unix.realpath source_path in
  let build_dir_of = Mach_config.build_dir_of config in
  let build_dir = build_dir_of source_path in
  let state_path = Filename.(build_dir / "Mach.state") in
  let prev_state, state, reconfigure_reason =
    match Mach_state.read state_path with
    | None ->
      log_very_verbose "mach:configure: no previous state found, creating one...";
      let state = Mach_state.collect_exn config source_path in
      None, state, (Some Mach_state.Env_changed)
    | Some state as prev_state ->
      match Mach_state.check_reconfigure_exn config state with
      | None -> prev_state, state, None
      | Some reason ->
        log_very_verbose "mach:configure: need reconfigure";
        let state = Mach_state.collect_exn config source_path in
        prev_state, state, (Some reason)
  in
  begin match reconfigure_reason with
  | None -> ()
  | Some reconfigure_reason ->
    log_verbose "mach: configuring...";
    let changed_paths = match reconfigure_reason with
      | Mach_state.Env_changed -> None  (* full reconfigure *)
      | Mach_state.Paths_changed set -> Some set
    in
    (* For full reconfigure, clean build directories; for partial, ninja cleandead handles it *)
    (match reconfigure_reason with
    | Env_changed ->
      Mach_state.libs state |> List.iter (fun lib -> rm_rf (build_dir_of lib.Mach_library.path));
      Mach_state.modules state |> List.iter (fun m -> rm_rf (build_dir_of m.Mach_module.path_ml));
    | Paths_changed _ -> ());
    mkdir_p build_dir;
    configure_backend config ~state ~prev_state ~changed_paths source_path;
    (* Clean up stale build outputs *)
    let cmd = sprintf "ninja -C %s -t cleandead > /dev/null" (Filename.quote build_dir) in
    if !Mach_log.verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
    if Sys.command cmd <> 0 then Mach_error.user_errorf "ninja cleandead failed";
    Mach_state.write state_path state
  end;
  state, (Option.is_some reconfigure_reason)

let configure config source_path =
  try Ok (configure_exn config source_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)

(* --- Build --- *)

let run_build cmd =
  let open Unix in
  let cmd = sprintf "%s 2>&1" cmd in
  let ic = open_process_in cmd in
  begin try while true do
    let line = input_line ic in
    if String.length line >= 3 && String.sub line 0 3 = ">>>" then
      prerr_endline (String.sub line 3 (String.length line - 3))
  done with End_of_file -> () end;
  match close_process_in ic with
  | WEXITED code -> code
  | WSIGNALED _ | WSTOPPED _ -> 1

let build_exn config script_path =
  let script_path = Unix.realpath script_path in
  let build_dir_of = Mach_config.build_dir_of config in
  let state, reconfigured = configure_exn config script_path in
  log_verbose "mach: building...";
  let cmd = if !Mach_log.verbose = Very_very_verbose then "ninja -v" else "ninja --quiet" in
  let cmd = sprintf "%s -C %s" cmd (Filename.quote (build_dir_of script_path)) in
  if !Mach_log.verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
  if run_build cmd <> 0 then Mach_error.user_errorf "build failed";
  let exe_path = Filename.(build_dir_of script_path / "a.out") in
  exe_path, state, reconfigured

let build config script_path =
  try Ok (build_exn config script_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
