(* mach_lib - Shared code for mach and mach-lsp *)

open! Mach_std
open Printf

type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let log_verbose = Mach_log.log_verbose
let log_very_verbose = Mach_log.log_very_verbose

let module_name_of_path path = Filename.(basename path |> remove_extension)

(* --- Build backend types (re-exported from Mach_config) --- *)

type build_backend = Mach_config.build_backend = Make | Ninja

(* --- Module kind (ML or MLX) --- *)

type module_kind = ML | MLX

let module_kind_of_path path =
  if Filename.extension path = ".mlx" then MLX else ML

let src_ext_of_kind = function ML -> ".ml" | MLX -> ".mlx"

(* --- PP (for merlin and build) --- *)

let pp source_path =
  In_channel.with_open_text source_path (fun ic ->
    Mach_module.preprocess_source ~source_path stdout ic);
  flush stdout

(* --- Configure --- *)

type ocaml_module = {
  ml_path: string;
  mli_path: string option;
  cmx: string;
  cmi: string;
  cmt: string;
  module_name: string;
  build_dir: string;
  resolved_requires: string with_loc list;  (* absolute paths *)
  libs: string with_loc list;  (* ocamlfind library names *)
  kind: module_kind;
}

let configure_backend config state =
  let build_backend = config.Mach_config.build_backend in
  let build_dir_of = Mach_config.build_dir_of config in
  let (module B : S.BUILD), module_file, root_file =
    match build_backend with
    | Make -> (module Makefile), "mach.mk", "Makefile"
    | Ninja -> (module Ninja), "mach.ninja", "build.ninja"
  in
  let cmd = state.Mach_state.header.mach_executable_path in
  let capture_outf fmt = ksprintf (sprintf "${MACH} run-build-command -- %s") fmt in
  let capture_stderrf fmt = ksprintf (sprintf "${MACH} run-build-command --stderr-only -- %s") fmt in
  let configure_ocaml_module b (m : ocaml_module) =
    let src_ext = src_ext_of_kind m.kind in
    let src = Filename.(m.build_dir / m.module_name ^ src_ext) in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    B.rulef b ~target:src ~deps:[m.ml_path] "%s pp %s > %s" cmd m.ml_path src;
    Option.iter (fun mli_path ->
      B.rulef b ~target:mli ~deps:[mli_path] "%s pp %s > %s" cmd mli_path mli
    ) m.mli_path;
    let args = Filename.(m.build_dir / "includes.args") in
    let recipe =
      match m.resolved_requires with
      | [] -> [sprintf "touch %s" args]
      | requires -> List.map (fun (r : _ with_loc) -> sprintf "echo '-I=%s' >> %s" (build_dir_of r.v) args) requires
    in
    B.rule b ~target:args ~deps:[src] (sprintf "rm -f %s" args :: recipe);
    (* Generate lib_includes.args for ocamlfind library include paths (only if libs present) *)
    (match m.libs with
    | [] -> ()
    | libs ->
      let lib_args = Filename.(m.build_dir / "lib_includes.args") in
      let libs = String.concat " " (List.map (fun (l : _ with_loc) -> l.v) libs) in
      B.rule b ~target:lib_args ~deps:[] [capture_stderrf "ocamlfind query -format '-I=%%d' -recursive %s > %s" libs lib_args])
  in
  let compile_ocaml_module b (m : ocaml_module) =
    let src_ext = src_ext_of_kind m.kind in
    let src = Filename.(m.build_dir / m.module_name ^ src_ext) in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    let args = Filename.(m.build_dir / "includes.args") in
    let pp_flag = match m.kind with ML -> "" | MLX -> " -pp mlx-pp" in
    let cmi_deps = List.map (fun (r : _ with_loc) -> Filename.(build_dir_of r.v / module_name_of_path r.v ^ ".cmi")) m.resolved_requires in
    let lib_args_dep, lib_args_cmd = match m.libs with
      | [] -> [], ""
      | _ -> [Filename.(m.build_dir / "lib_includes.args")], sprintf " -args %s" Filename.(m.build_dir / "lib_includes.args")
    in
    match m.mli_path with
    | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first (using ocamlc for speed), then .ml to .cmx *)
      B.rule b ~target:m.cmi ~deps:(mli :: args :: lib_args_dep @ cmi_deps)
        [capture_outf "ocamlc%s -bin-annot -c -opaque -args %s%s -o %s %s" pp_flag args lib_args_cmd m.cmi mli];
      B.rule b ~target:m.cmx ~deps:([src; m.cmi; args] @ lib_args_dep)
        [capture_outf "ocamlopt%s -bin-annot -c -args %s%s -cmi-file %s -o %s -impl %s" pp_flag args lib_args_cmd m.cmi m.cmx src];
      B.rule b ~target:m.cmt ~deps:[m.cmx] []
    | None -> (* Without .mli: ocamlopt produces both .cmi and .cmx *)
      B.rule b ~target:m.cmx ~deps:(src :: args :: lib_args_dep @ cmi_deps)
        [capture_outf "ocamlopt%s -bin-annot -c -args %s%s -o %s -impl %s" pp_flag args lib_args_cmd m.cmx src];
      B.rule b ~target:m.cmi ~deps:[m.cmx] [];
      B.rule b ~target:m.cmt ~deps:[m.cmx] []
  in
  let link_ocaml_module b (all_objs : string list) (all_libs : string list) ~exe_path =
    let root_build_dir = Filename.dirname exe_path in
    let args = Filename.(root_build_dir / "all_objects.args") in
    let objs_str = String.concat " " all_objs in
    B.rulef b ~target:args ~deps:all_objs "printf '%%s\\n' %s > %s" objs_str args;
    match all_libs with
    | [] ->
      B.rule b ~target:exe_path ~deps:(args :: all_objs)
        [capture_outf "ocamlopt -o %s -args %s" exe_path args]
    | libs ->
      let lib_args = Filename.(root_build_dir / "lib_objects.args") in
      let libs = String.concat " " libs in
      B.rule b ~target:lib_args ~deps:[] [capture_stderrf "ocamlfind query -a-format -recursive -predicates native %s > %s" libs lib_args];
      B.rule b ~target:exe_path ~deps:(args :: lib_args :: all_objs)
        [capture_outf "ocamlopt -o %s -args %s -args %s" exe_path lib_args args]
  in
  let modules = List.map (fun ({ml_path;mli_path;requires=resolved_requires;libs;_} : Mach_state.entry) ->
    let module_name = module_name_of_path ml_path in
    let build_dir = build_dir_of ml_path in
    let kind = module_kind_of_path ml_path in
    let cmx = Filename.(build_dir / module_name ^ ".cmx") in
    let cmi = Filename.(build_dir / module_name ^ ".cmi") in
    let cmt = Filename.(build_dir / module_name ^ ".cmt") in
    { ml_path; mli_path; module_name; build_dir; resolved_requires;cmx;cmi;cmt;libs;kind }
  ) state.Mach_state.entries in
  (* Generate per-module build files *)
  List.iter (fun (m : ocaml_module) ->
    mkdir_p m.build_dir;
    let file_path = Filename.(m.build_dir / module_file) in
    write_file file_path (
      let b = B.create () in
      configure_ocaml_module b m;
      compile_ocaml_module b m;
      B.contents b)
  ) modules;
  (* Generate root build file *)
  let exe_path = Mach_state.exe_path config state in
  let all_objs = List.map (fun m -> m.cmx) modules in
  let all_libs = Mach_state.all_libs state in
  write_file Filename.(build_dir_of state.root.ml_path / root_file) (
    let b = B.create () in
    B.var b "MACH" cmd;
    List.iter (fun entry ->
      B.include_ b Filename.(build_dir_of entry.Mach_state.ml_path / module_file)) state.entries;
    B.rule_phony b ~target:"all" ~deps:[exe_path];
    link_ocaml_module b all_objs all_libs ~exe_path;
    B.contents b
  )

let configure_exn config source_path =
  let build_dir_of = Mach_config.build_dir_of config in
  let source_path = Unix.realpath source_path in
  let build_dir = build_dir_of source_path in
  let state_path = Filename.(build_dir / "Mach.state") in
  let state, needs_reconfigure =
    match Mach_state.read state_path with
    | None ->
      log_very_verbose "mach:configure: no previous state found, creating one...";
      Mach_state.collect_exn config source_path, true
    | Some state when Mach_state.needs_reconfigure_exn config state ->
      log_very_verbose "mach:configure: need reconfigure";
      Mach_state.collect_exn config source_path, true
    | Some state -> state, false
  in
  if needs_reconfigure then begin
    log_verbose "mach: configuring...";
    List.iter (fun entry -> rm_rf (build_dir_of entry.Mach_state.ml_path)) state.entries;
    mkdir_p build_dir;
    configure_backend config state;
    Mach_state.write state_path state
  end;
  ~state, ~reconfigured:needs_reconfigure

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
  let build_dir_of = Mach_config.build_dir_of config in
  let ~state, ~reconfigured = configure_exn config script_path in
  log_verbose "mach: building...";
  let cmd = match config.Mach_config.build_backend with
    | Make -> if !Mach_log.verbose = Very_very_verbose then "make all" else "make -s all"
    | Ninja -> if !Mach_log.verbose = Very_very_verbose then "ninja -v" else "ninja --quiet"
  in
  let cmd = sprintf "%s -C %s" cmd (Filename.quote (build_dir_of state.root.ml_path)) in
  if !Mach_log.verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
  if run_build cmd <> 0 then Mach_error.user_errorf "build failed";
  ~state, ~reconfigured

let build config script_path =
  try Ok (build_exn config script_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
