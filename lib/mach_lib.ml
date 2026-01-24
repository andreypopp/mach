(* mach_lib - Shared code for mach and mach-lsp *)

open! Mach_std
open Printf

type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let log_verbose = Mach_log.log_verbose
let log_very_verbose = Mach_log.log_very_verbose

let module_name_of_path path = Filename.(basename path |> remove_extension)

(* --- Module kind (ML or MLX) --- *)

type module_kind = ML | MLX

let module_kind_of_path path =
  if Filename.extension path = ".mlx" then MLX else ML

let src_ext_of_kind = function ML -> ".ml" | MLX -> ".mlx"

(* --- PP (for merlin and build) --- *)

let pp ~source_path ic oc =
  Mach_module.preprocess_source ~source_path oc ic

(* --- Configure --- *)

type ocaml_module = {
  m : Mach_module.t;
  cmx: string;
  cmi: string;
  cmt: string;
  module_name: string;
  build_dir: string;
}

let configure_backend config ~state ~prev_state ~changed_paths script_path =
  let build_dir_of = Mach_config.build_dir_of config in
  let module_file = "mach.ninja" in
  let root_file = "build.ninja" in
  let cmd = config.Mach_config.mach_executable_path in
  let capture_outf fmt = ksprintf (sprintf "${MACH} run-build-command -- %s") fmt in
  let capture_stderrf fmt = ksprintf (sprintf "${MACH} run-build-command --stderr-only -- %s") fmt in

  let configure_ocaml_module b (m : ocaml_module) =
    let src =
      (* preprocess .ml *)
      let src = Filename.(m.build_dir / m.module_name ^ ".ml") in
      let pp_flag = match m.m.kind with ML -> "" | MLX -> " --pp mlx-pp" in
      Ninja.rulef b ~target:src ~deps:[m.m.path_ml] "%s pp%s -o %s %s" cmd pp_flag src m.m.path_ml;
      src
    in
    let () =
      (* preprocess .mli *)
      Option.iter (fun mli_path ->
        let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
        Ninja.rulef b ~target:mli ~deps:[mli_path] "%s pp -o %s %s" cmd mli mli_path) m.m.path_mli
    in
    let path_requires = List.filter_map (function
      | Mach_module.Require r | Mach_module.Require_lib r -> Some r
      | Mach_module.Require_extlib _ -> None
    ) m.m.requires in
    let extlib_requires = List.filter_map (function
      | Mach_module.Require_extlib l -> Some l
      | Mach_module.Require _ | Mach_module.Require_lib _ -> None
    ) m.m.requires in
    let () =
      (* generate includes.args *)
      let args = Filename.(m.build_dir / "includes.args") in
      let recipe =
        match path_requires with
        | [] -> [sprintf "touch %s" args]
        | requires -> List.map (fun (r : _ with_loc) -> sprintf "echo '-I=%s' >> %s" (build_dir_of r.v) args) requires
      in
      Ninja.rule b ~target:args ~deps:[src] (sprintf "rm -f %s" args :: recipe)
    in
    let () =
      (* generate lib_includes.args (ocamlfind libraries include paths, only if libs present) *)
      (match extlib_requires with
      | [] -> ()
      | libs ->
        let lib_args = Filename.(m.build_dir / "lib_includes.args") in
        let libs = String.concat " " (List.map (fun (l : Mach_module.extlib with_loc) -> l.v.name) libs) in
        Ninja.rule b ~target:lib_args ~deps:[] [capture_stderrf "ocamlfind query -format '-I=%%d' -recursive %s > %s" libs lib_args])
    in
    ()
  in
  let compile_ocaml_module b (m : ocaml_module) =
    let src = Filename.(m.build_dir / m.module_name ^ ".ml") in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    let args = Filename.(m.build_dir / "includes.args") in
    (* Dependencies: for modules depend on .cmi, for libraries depend on .cmxa *)
    let cmi_deps = List.filter_map (function
      | Mach_module.Require r ->
        (* Module dependency - depend on .cmi *)
        Some Filename.(build_dir_of r.v / module_name_of_path r.v ^ ".cmi")
      | Mach_module.Require_lib r ->
        (* Library dependency - depend on .cmxa *)
        Some Filename.(build_dir_of r.v / Filename.basename r.v ^ ".cmxa")
      | Mach_module.Require_extlib _ -> None
    ) m.m.requires in
    let has_extlibs = List.exists (function Mach_module.Require_extlib _ -> true | _ -> false) m.m.requires in
    let lib_args_dep, lib_args_cmd =
      if has_extlibs
      then [Filename.(m.build_dir / "lib_includes.args")], sprintf " -args %s" Filename.(m.build_dir / "lib_includes.args")
      else [], ""
    in
    match m.m.path_mli with
    | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first (using ocamlc for speed), then .ml to .cmx *)
      Ninja.rule b ~target:m.cmi ~deps:(mli :: args :: lib_args_dep @ cmi_deps)
        [capture_outf "ocamlc -bin-annot -c -opaque -args %s%s -o %s %s" args lib_args_cmd m.cmi mli];
      Ninja.rule b ~target:m.cmx ~deps:([src; m.cmi; args] @ lib_args_dep)
        [capture_outf "ocamlopt -bin-annot -c -args %s%s -cmi-file %s -o %s -impl %s" args lib_args_cmd m.cmi m.cmx src];
      Ninja.rule b ~target:m.cmt ~deps:[m.cmx] []
    | None -> (* Without .mli: ocamlopt produces both .cmi and .cmx *)
      Ninja.rule b ~target:m.cmx ~deps:(src :: args :: lib_args_dep @ cmi_deps)
        [capture_outf "ocamlopt -bin-annot -c -args %s%s -o %s -impl %s" args lib_args_cmd m.cmx src];
      Ninja.rule b ~target:m.cmi ~deps:[m.cmx] [];
      Ninja.rule b ~target:m.cmt ~deps:[m.cmx] []
  in
  let link_ocaml_module b (all_objs : string list) ~(extlibs : string list) ~(libs : Mach_library.t list) ~exe_path =
    let root_build_dir = Filename.dirname exe_path in
    let args = Filename.(root_build_dir / "all_objects.args") in
    (* Include both .cmx files and mach library .cmxa files *)
    let all_link_objs = (List.map (Mach_library.cmxa config) libs) @ all_objs in
    let objs_str = String.concat " " all_link_objs in
    Ninja.rulef b ~target:args ~deps:all_link_objs "printf '%%s\\n' %s > %s" objs_str args;
    match extlibs with
    | [] ->
      Ninja.rule b ~target:exe_path ~deps:(args :: all_link_objs)
        [capture_outf "ocamlopt -o %s -args %s" exe_path args]
    | libs ->
      let lib_args = Filename.(root_build_dir / "lib_objects.args") in
      let libs = String.concat " " libs in
      Ninja.rule b ~target:lib_args ~deps:[] [capture_stderrf "ocamlfind query -a-format -recursive -predicates native %s > %s" libs lib_args];
      Ninja.rule b ~target:exe_path ~deps:(args :: lib_args :: all_link_objs)
        [capture_outf "ocamlopt -o %s -args %s -args %s" exe_path lib_args args]
  in
  let modules = List.map (fun (m : Mach_module.t) ->
      let module_name = module_name_of_path m.path_ml in
      let build_dir = build_dir_of m.path_ml in
      let cmx = Filename.(build_dir / module_name ^ ".cmx") in
      let cmi = Filename.(build_dir / module_name ^ ".cmi") in
      let cmt = Filename.(build_dir / module_name ^ ".cmt") in
      { m; module_name; build_dir; cmx; cmi; cmt }
  ) (Mach_state.modules state) in
  let old_modules, old_libs = match prev_state with
    | None -> SS.empty, SS.empty
    | Some old ->
      let libs = Mach_state.libs old |> List.map (fun lib -> lib.Mach_library.path) in
      let modules = Mach_state.modules old |> List.map (fun lib -> lib.Mach_module.path_ml) in
      SS.of_list modules, SS.of_list libs
  in
  (* Generate per-module build files - only for changed/new modules *)
  List.iter (fun (m : ocaml_module) ->
    let needs_configure = match changed_paths with
      | None -> true  (* full reconfigure *)
      | Some changed_paths -> SS.mem m.m.path_ml changed_paths || not (SS.mem m.m.path_ml old_modules)
    in
    if needs_configure then begin
      log_verbose "mach: configuring %s" m.m.path_ml;
      mkdir_p m.build_dir;
      let file_path = Filename.(m.build_dir / module_file) in
      write_file file_path (
        let b = Ninja.create () in
        configure_ocaml_module b m;
        compile_ocaml_module b m;
        Ninja.contents b)
    end
  ) modules;
  (* Configure libraries *)
  let libs = Mach_state.libs state in
  List.iter (fun (lib : Mach_library.t) ->
    let needs_configure = match changed_paths with
      | None -> true  (* full reconfigure *)
      | Some changed -> SS.mem lib.path changed || not (SS.mem lib.path old_libs)
    in
    if needs_configure then begin
      log_verbose "mach: configuring library %s" lib.path;
      Mach_library.configure_library config lib
    end
  ) libs;
  (* Generate root build file *)
  let exe_path = Filename.(build_dir_of script_path / "a.out") in
  let all_objs = List.map (fun m -> m.cmx) modules in
  let extlibs = Mach_state.extlibs state in
  write_file Filename.(build_dir_of script_path / root_file) (
    log_verbose "mach: configuring %s (root)" script_path;
    let b = Ninja.create () in
    Ninja.var b "MACH" cmd;
    List.iter (fun lib -> Ninja.subninja b Filename.(build_dir_of lib.Mach_library.path / module_file)) libs;
    List.iter (fun m -> Ninja.subninja b Filename.(build_dir_of m.m.path_ml / module_file)) modules;
    Ninja.rule_phony b ~target:"all" ~deps:[exe_path];
    link_ocaml_module b all_objs ~extlibs ~libs ~exe_path;
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
