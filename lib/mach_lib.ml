(* mach_lib - Shared code for mach and mach-lsp *)

open! Mach_std
open Printf

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
      ~requires:!!(m.requires)
      ~build_dir
      ~deps:[ml]
  in
  Mach_ocaml_rules.compile_ocaml_module ninja config
    ~path_ml:m.path_ml
    ~path_mli:m.path_mli
    ~requires:!!(m.requires)
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

let configure_exn config target =
  let target_path = target_path target in
  let build_dir_of = Mach_config.build_dir_of config in
  let modules, libs = Mach_state.crawl config ~target_path in
  let any_need_reconfigure = ref false in
  let modules =
    List.map (fun {Mach_state.unit=m;state;need_configure} ->
      let build_dir = build_dir_of m.Mach_module.path_ml in
      if need_configure then begin
        any_need_reconfigure := true;
        log_verbose "mach: configuring %s" m.path_ml;
        mkdir_p build_dir;
        let b = Ninja.create () in
        let _cmi, cmx = configure_module ~build_dir b config m in
        write_file Filename.(build_dir / "mach.ninja") (Ninja.contents b);
        Mach_state.write config state;
        m, cmx
      end
      else m, Mach_module.cmx config m
    ) modules
  in
  let modules, cmxs = List.split modules in
  let libs =
    List.map (fun {Mach_state.unit=lib;state;need_configure} ->
      if need_configure then begin
        any_need_reconfigure := true;
        log_verbose "mach: configuring library %s" lib.Mach_library.path;
        let build_dir = Mach_config.build_dir_of config lib.path in
        let mach_cmd = config.Mach_config.mach_executable_path in
        mkdir_p build_dir;
        let b = Ninja.create () in
        Ninja.var b "MACH" mach_cmd;
        configure_library b config lib ~build_dir;
        write_file Filename.(build_dir / "mach.ninja") (Ninja.contents b);
        Mach_state.write config state;
      end;
      lib
    ) libs
  in
  let any_need_reconfigure = !any_need_reconfigure in
  if any_need_reconfigure then begin
    let build_dir = build_dir_of target_path in
    mkdir_p build_dir;
    (* Generate root build file *)
    write_file Filename.(build_dir / "build.ninja") (
      log_verbose "mach: configuring %s (root)" target_path;
      let b = Ninja.create () in
      Ninja.var b "MACH" config.Mach_config.mach_executable_path;
      List.iter (fun lib -> Ninja.subninja b Filename.(build_dir_of lib.Mach_library.path / "mach.ninja")) libs;
      List.iter (fun m -> Ninja.subninja b Filename.(build_dir_of m.Mach_module.path_ml / "mach.ninja")) modules;
        begin match target with
        | Target_library lib_path ->
          (* For library targets, just build the library's .cmxa *)
          let cmxa_path = Filename.(build_dir_of lib_path / Filename.basename lib_path ^ ".cmxa") in
          Ninja.rule_phony b ~target:"all" ~deps:[cmxa_path]
        | Target_executable _ ->
          (* For executable targets, link to a.out *)
          let exe_path = Filename.(build_dir / "a.out") in
          let extlibs =
            let extlibs = SS.empty in
            let extlibs =
              List.fold_left
                (fun acc lib -> SS.add_seq (Mach_library.extlibs lib |> List.to_seq) acc)
                extlibs libs
            in
            let extlibs =
              List.fold_left
                (fun acc m -> SS.add_seq (Mach_module.extlibs m |> List.to_seq) acc)
                extlibs modules
            in
            SS.elements extlibs
          in
          let cmxas = List.map (Mach_library.cmxa config) libs in
          Ninja.rule_phony b ~target:"all" ~deps:[exe_path];
          Mach_ocaml_rules.link_ocaml_executable b config
            ~exe_path
            ~extlibs
            ~cmxs
            ~cmxas
            ~build_dir
        end;
        Ninja.contents b
    );
    (* Clean dead files *)
    let cmd = sprintf "ninja -C %s -t cleandead > /dev/null" (Filename.quote build_dir) in
    if !Mach_log.verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
    if Sys.command cmd <> 0 then Mach_error.user_errorf "ninja cleandead failed"
  end;
  any_need_reconfigure, modules, libs

let configure config target =
  try Ok (configure_exn config target)
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

let build_exn config target =
  let source_path = target_path target in
  let build_dir_of = Mach_config.build_dir_of config in
  let reconfigured, modules, libs = configure_exn config target in
  log_verbose "mach: building...";
  let cmd = if !Mach_log.verbose = Very_very_verbose then "ninja -v" else "ninja --quiet" in
  let cmd = sprintf "%s -C %s" cmd (Filename.quote (build_dir_of source_path)) in
  if !Mach_log.verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
  if run_build cmd <> 0 then Mach_error.user_errorf "build failed";
  let output_path = match target with
    | Target_executable _ -> Filename.(build_dir_of source_path / "a.out")
    | Target_library lib_path -> Filename.(build_dir_of lib_path / Filename.basename lib_path ^ ".cmxa")
  in
  output_path, reconfigured, modules, libs

let build config target =
  try Ok (build_exn config target)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
