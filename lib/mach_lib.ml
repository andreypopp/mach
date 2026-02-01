(* mach_lib - Shared code for mach and mach-lsp *)

open! Mach_std

type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let log_verbose = Mach_log.log_verbose

(* --- Target type --- *)

type target =
  | Target_executable of string  (** path to module which defines an executable *)
  | Target_library of string     (** path to library directory *)

let resolve_target config path =
  let path = Unix.realpath path in
  match Mach_module.resolve_require config ~source_path:path ~line:0 path with
  | Mach_module.Require r -> Target_executable r.v
  | Mach_module.Require_lib r -> Target_library r.v
  | Mach_module.Require_extlib _ -> failwith "impossible as the input is a path"

let target_path = function
  | Target_executable p
  | Target_library p -> p

(* --- PP (for merlin and build) --- *)

let pp ~source_path ic oc =
  Mach_module.preprocess_source ~source_path oc ic

(* --- Configure --- *)

let configure_module ~build_dir rules config (m : Mach_module.t) =
  let ppx_driver =
    Mach_ocaml_rules.compile_ppx_driver rules config
      ~build_dir
      ~ppxes:!!(m.ppxes)
  in
  let _ocamldep_args, _compile_args =
    let ml, _mli =
      Mach_ocaml_rules.preprocess_ocaml_module rules config
        ~build_dir
        ~path_ml:m.path_ml
        ~path_mli:m.path_mli
        ~kind:m.kind
        ?ppx_driver
        ()
    in
    Mach_ocaml_rules.compile_ocaml_args rules config
      ~requires:!!(m.requires)
      ~build_dir
      ~deps:[ml]
  in
  Mach_ocaml_rules.compile_ocaml_module rules config
    ~path_ml:m.path_ml
    ~path_mli:m.path_mli
    ~requires:!!(m.requires)
    ~build_dir

let configure_library ~build_dir rules config (lib : Mach_library.t) =
  let lib_name = Filename.basename lib.path in
  let ppx_driver =
    Mach_ocaml_rules.compile_ppx_driver rules config
      ~build_dir
      ~ppxes:!!(lib.ppxes)
  in
  let ocamldep_args, _compile_args =
    Mach_ocaml_rules.compile_ocaml_args ~include_self:true rules config
      ~requires:!!(lib.requires)
      ~build_dir
      ~deps:[Filename.(lib.path / "Machlib")]
  in
  let deps, cmxs =
    List.map (fun (m : Mach_library.lib_module) ->
      let src_ml = Filename.(lib.path / m.file_ml) in
      let src_mli = Option.map (fun file_mli -> Filename.(lib.path / file_mli)) m.file_mli in
      let ml, mli =
        Mach_ocaml_rules.preprocess_ocaml_module rules config
          ~build_dir
          ~path_ml:src_ml
          ~path_mli:src_mli
          ~kind:(Mach_module.kind_of_path_ml src_ml)
          ?ppx_driver
          ();
      in
      let path_dep = Mach_ocaml_rules.ocamldep rules config
        ~build_dir
        ~path_ml:ml
        ~includes_args:ocamldep_args
      in
      let _cmi, cmx =
        Mach_ocaml_rules.compile_ocaml_module rules config
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
  Mach_ocaml_rules.link_ocaml_library rules config
    ~build_dir
    ~cmxs
    ~deps
    ~lib_name

let configure_exn config target =
  let target_path = target_path target in
  let build_dir_of = Mach_config.build_dir_of config in
  let units = Mach_state.crawl config ~target_path in
  let any_need_reconfigure = ref false in
  (* Process units in dependency order, collecting modules, libs, and link objects *)
  let modules = ref [] in
  let libs = ref [] in
  let objs = ref [] in  (* Combined list of .cmx and .cmxa in dependency order *)
  let extlibs = ref SS.empty in
  let build_system = Mach_build.create () in
  List.iter (fun {Mach_state.unit; unit_state; unit_status} ->
    match unit with
    | Mach_state.Unit_module m ->
      let build_dir = build_dir_of m.Mach_module.path_ml in
      let mach_build = Filename.(build_dir / "Mach.build") in
      let cmx =
        match unit_status with
        | `Need_configure ->
          any_need_reconfigure := true;
          log_verbose "mach: configuring %s" m.path_ml;
          rm_rf build_dir;
          mkdir_p build_dir;
          let rules = Mach_build.Rules.create () in
          let _cmi, cmx = configure_module ~build_dir rules config m in
          let build = Mach_build.Rules.to_list rules in
          Mach_build.configure build_system build;
          write_file mach_build (Mach_build.Build_file_format.to_string build);
          Mach_state.write config unit_state;
          cmx
        | `Fresh_but_update_state ->
          Mach_build.(configure build_system (Build_file_format.of_file mach_build));
          Mach_state.write config unit_state;
          Mach_module.cmx config m
        | `Fresh ->
          Mach_build.(configure build_system (Build_file_format.of_file mach_build));
          Mach_module.cmx config m
      in
      modules := m :: !modules;
      objs := cmx :: !objs;
      extlibs := SS.union (Mach_module.extlibs m) !extlibs
    | Mach_state.Unit_lib lib ->
      let build_dir = Mach_config.build_dir_of config lib.path in
      let mach_build = Filename.(build_dir / "Mach.build") in
      begin match unit_status with
      | `Need_configure ->
        any_need_reconfigure := true;
        log_verbose "mach: configuring library %s" lib.Mach_library.path;
        rm_rf build_dir;
        mkdir_p build_dir;
        let rules = Mach_build.Rules.create () in
        configure_library rules config lib ~build_dir;
        let build = Mach_build.Rules.to_list rules in
        Mach_build.configure build_system build;
        write_file mach_build (Mach_build.Build_file_format.to_string build);
        Mach_state.write config unit_state
      | `Fresh_but_update_state ->
        Mach_build.(configure build_system (Build_file_format.of_file mach_build));
        Mach_state.write config unit_state
      | `Fresh ->
        Mach_build.(configure build_system (Build_file_format.of_file mach_build));
      end;
      libs := lib :: !libs;
      objs := Mach_library.cmxa config lib :: !objs;
      extlibs := SS.union (Mach_library.extlibs lib) !extlibs
  ) units;
  let modules = List.rev !modules in
  let libs = List.rev !libs in
  let objs = List.rev !objs in
  let extlibs = SS.elements !extlibs in
  let any_need_reconfigure = !any_need_reconfigure in
  begin match target with
  | Target_library _ -> ()
  | Target_executable _ ->
    let build_dir = build_dir_of target_path in
    let exe_path = Filename.(build_dir / "a.out") in
    let rules = Mach_build.Rules.create () in
    Mach_ocaml_rules.link_ocaml_executable rules config
      ~exe_path
      ~extlibs
      ~objs
      ~build_dir;
    Mach_build.configure build_system (Mach_build.Rules.to_list rules)
  end;
  any_need_reconfigure, build_system, modules, libs

let configure config target =
  try Ok (configure_exn config target)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)

(* --- Build --- *)

let build_exn config target =
  let source_path = target_path target in
  let build_dir_of = Mach_config.build_dir_of config in
  let reconfigured, build_system, modules, libs = configure_exn config target in
  log_verbose "mach: building...";
  let build_dir = build_dir_of source_path in
  let target_path = match target with
    | Target_executable _ -> Filename.(build_dir / "a.out")
    | Target_library lib_path -> Filename.(build_dir_of lib_path / Filename.basename lib_path ^ ".cmxa")
  in
  Mach_build.build build_system ~target_path ~parallelism:config.parallelism;
  target_path, reconfigured, modules, libs

let build config target =
  try Ok (build_exn config target)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)

module Build = Mach_build
