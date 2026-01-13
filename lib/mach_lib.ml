(* mach_lib - Shared code for mach and mach-lsp *)

(* --- Utilities --- *)

open Printf

type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let log_verbose = Mach_log.log_verbose
let log_very_verbose = Mach_log.log_very_verbose

module Filename = struct
  include Filename
  let (/) = concat
end

module Buffer = struct
  include Buffer
  let output_line oc line = output_string oc line; output_char oc '\n'
end

let module_name_of_path path = Filename.(basename path |> remove_extension)

let failwithf fmt = ksprintf failwith fmt
let rm_rf path =
  let cmd = sprintf "rm -rf %s" (Filename.quote path) in
  if Sys.command cmd <> 0 then failwithf "Command failed: %s" cmd

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let write_file path content = Out_channel.with_open_text path (fun oc -> output_string oc content)

(* --- Build backend types (re-exported from Mach_config) --- *)

type build_backend = Mach_config.build_backend = Make | Ninja

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
  resolved_requires: string list;  (* absolute paths *)
  libs: string list;  (* ocamlfind library names *)
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
  let configure_ocaml_module b (m : ocaml_module) =
    let ml = Filename.(m.build_dir / m.module_name ^ ".ml") in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    B.rulef b ~target:ml ~deps:[m.ml_path] "%s pp %s > %s" cmd m.ml_path ml;
    Option.iter (fun mli_path ->
      B.rulef b ~target:mli ~deps:[mli_path] "%s pp %s > %s" cmd mli_path mli
    ) m.mli_path;
    let args = Filename.(m.build_dir / "includes.args") in
    let recipe =
      match m.resolved_requires with
      | [] -> [sprintf "touch %s" args]
      | requires -> List.map (fun p -> sprintf "echo '-I=%s' >> %s" (build_dir_of p) args) requires
    in
    B.rule b ~target:args ~deps:[ml] (sprintf "rm -f %s" args :: recipe);
    (* Generate lib_includes.args for ocamlfind library include paths (only if libs present) *)
    (match m.libs with
    | [] -> ()
    | libs ->
      let lib_args = Filename.(m.build_dir / "lib_includes.args") in
      let libs_str = String.concat " " libs in
      B.rulef b ~target:lib_args ~deps:[] "ocamlfind query -format '-I=%%d' -recursive %s > %s" libs_str lib_args)
  in
  let compile_ocaml_module b (m : ocaml_module) =
    let ml = Filename.(m.build_dir / m.module_name ^ ".ml") in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    let args = Filename.(m.build_dir / "includes.args") in
    let cmi_deps = List.map (fun p -> Filename.(build_dir_of p / module_name_of_path p ^ ".cmi")) m.resolved_requires in
    let lib_args_dep, lib_args_cmd = match m.libs with
      | [] -> [], ""
      | _ -> [Filename.(m.build_dir / "lib_includes.args")], sprintf " -args %s" Filename.(m.build_dir / "lib_includes.args")
    in
    match m.mli_path with
    | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first (using ocamlc for speed), then .ml to .cmx *)
      B.rulef b ~target:m.cmi ~deps:(mli :: args :: lib_args_dep @ cmi_deps) "ocamlc -bin-annot -c -opaque -args %s%s -o %s %s" args lib_args_cmd m.cmi mli;
      B.rulef b ~target:m.cmx ~deps:([ml; m.cmi; args] @ lib_args_dep) "ocamlopt -bin-annot -c -args %s%s -cmi-file %s -o %s %s" args lib_args_cmd m.cmi m.cmx ml;
      B.rule b ~target:m.cmt ~deps:[m.cmx] []
    | None -> (* Without .mli: ocamlopt produces both .cmi and .cmx *)
      B.rulef b ~target:m.cmx ~deps:(ml :: args :: lib_args_dep @ cmi_deps) "ocamlopt -bin-annot -c -args %s%s -o %s %s" args lib_args_cmd m.cmx ml;
      B.rule b ~target:m.cmi ~deps:[m.cmx] [];
      B.rule b ~target:m.cmt ~deps:[m.cmx] []
  in
  let link_ocaml_module b (all_objs : string list) (all_libs : string list) ~exe_path =
    let root_build_dir = Filename.dirname exe_path in
    let args = Filename.(root_build_dir / "all_objects.args") in
    let objs_str = String.concat " " all_objs in
    B.rulef b ~target:args ~deps:all_objs "printf '%%s\\n' %s > %s" objs_str args;
    match all_libs with
    | [] -> B.rulef b ~target:exe_path ~deps:(args :: all_objs) "ocamlopt -o %s -args %s" exe_path args
    | libs ->
      let lib_args = Filename.(root_build_dir / "lib_objects.args") in
      let libs_str = String.concat " " libs in
      B.rulef b ~target:lib_args ~deps:[] "ocamlfind query -a-format -recursive -predicates native %s > %s" libs_str lib_args;
      B.rulef b ~target:exe_path ~deps:(args :: lib_args :: all_objs) "ocamlopt -o %s -args %s -args %s" exe_path lib_args args
  in
  let modules = List.map (fun ({ml_path;mli_path;requires=resolved_requires;libs;_} : Mach_state.entry) ->
    let module_name = module_name_of_path ml_path in
    let build_dir = build_dir_of ml_path in
    let cmx = Filename.(build_dir / module_name ^ ".cmx") in
    let cmi = Filename.(build_dir / module_name ^ ".cmi") in
    let cmt = Filename.(build_dir / module_name ^ ".cmt") in
    { ml_path; mli_path; module_name; build_dir; resolved_requires;cmx;cmi;cmt;libs }
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
  if Sys.command cmd <> 0 then Mach_error.user_errorf "build failed";
  ~state, ~reconfigured

let build config script_path =
  try Ok (build_exn config script_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)

(* --- Watch mode --- *)

let parse_event line =
  match String.index_opt line ':' with
  | None -> None
  | Some i ->
    let event_type = String.sub line 0 i in
    let path = String.sub line (i + 1) (String.length line - i - 1) in
    Some (event_type, path)

(* Read a batch of events until empty line, deduplicating paths *)
let read_events ic =
  let paths = Hashtbl.create 16 in
  let rec loop () =
    match input_line ic with
    | "" -> Hashtbl.to_seq_keys paths |> List.of_seq |> List.sort String.compare
    | line -> begin
      log_very_verbose "mach:watch: event: %s" line;
      (match parse_event line with
      | None -> ()
      | Some (_event_type, path) -> Hashtbl.replace paths path ());
      loop ()
    end
  in
  loop ()

let watch_exn config script_path =
  let build_dir_of = Mach_config.build_dir_of config in
  let exception Restart_watcher in
  let code = Sys.command "command -v watchexec > /dev/null 2>&1" in
  if code <> 0 then
    Mach_error.user_errorf "watchexec not found. Install it: https://github.com/watchexec/watchexec";
  let script_path = Unix.realpath script_path in

  log_verbose "mach: initial build...";
  let ~state:_, ~reconfigured:_ = build_exn config script_path in

  (* Track current state for signal handling and cleanup *)
  let current_process = ref None in
  let current_watchlist = ref None in

  let cleanup () =
    !current_process |> Option.iter (fun (ic, oc) ->
      begin try close_out oc with _ -> () end;  (* Close stdin to trigger --stdin-quit *)
      begin try ignore (Unix.close_process (ic, oc)) with _ -> () end;
      current_process := None);
    !current_watchlist |> Option.iter (fun path ->
      begin try Sys.remove path with _ -> () end;
      current_watchlist := None)
  in

  Sys.(set_signal sigint (Signal_handle (fun _ -> cleanup (); exit 0)));

  let keep_watching = ref true in
  while !keep_watching do
    let state = Option.get (Mach_state.read Filename.(build_dir_of script_path / "Mach.state")) in
    let source_dirs = Mach_state.source_dirs state in
    let source_files =
      let files = Hashtbl.create 16 in
      List.iter (fun (entry : Mach_state.entry) ->
        Hashtbl.replace files entry.ml_path ();
        Option.iter (fun mli -> Hashtbl.replace files mli ()) entry.mli_path
      ) state.entries;
      files
    in
    log_verbose "mach: watching %d directories (Ctrl+C to stop):" (List.length source_dirs);
    List.iter (fun d -> log_verbose "  %s" d) source_dirs;
    let watchlist_path =
      let path = Filename.temp_file "mach-watch" ".txt" in
      Out_channel.with_open_text path (fun oc ->
        List.iter (fun dir -> Buffer.output_line oc "-W"; Buffer.output_line oc dir) source_dirs);
      path
    in
    current_watchlist := Some watchlist_path;
    let cmd = sprintf "watchexec --debounce 200ms --only-emit-events --emit-events-to=stdio --stdin-quit -e ml,mli @%s" watchlist_path in
    log_very_verbose "mach:watch: running: %s" cmd;

    let (ic, oc) = Unix.open_process cmd in
    current_process := Some (ic, oc);

    begin try
      while true do
        let changed_paths = read_events ic in
        let relevant_paths =
          List.fold_left (fun acc path -> if Hashtbl.mem source_files path then path :: acc else acc)
          [] changed_paths
        in
        if relevant_paths <> [] then begin
          List.iter (fun p -> log_verbose "mach: file changed: %s" (Filename.basename p)) relevant_paths;
          match build config script_path with
          | Error (`User_error msg) -> log_verbose "mach: %s" msg
          | Ok (~state:_, ~reconfigured) ->
            eprintf "mach: build succeeded\n%!";
            if reconfigured then begin
              log_verbose "mach:watch: reconfigured, restarting watcher...";
              raise Restart_watcher
            end
        end
      done
    with
    | Restart_watcher -> cleanup ()
    | End_of_file -> cleanup (); keep_watching := false
    end
  done

let watch config script_path =
  try Ok (watch_exn config script_path)
  with Mach_error.Mach_user_error msg -> Error (`User_error msg)
