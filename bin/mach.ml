(* mach - OCaml scripting runtime *)

open Mach_lib
open Mach_std

let or_exit = function
  | Ok v -> v
  | Error (`User_error msg) ->
    Printf.eprintf "mach: %s\n%!" msg;
    exit 1

(* --- Temp file management --- *)

let temp_filenames = ref []
let () =
  at_exit (fun () ->
    List.iter (fun path ->
      try Sys.remove path with _ -> ()
    ) !temp_filenames)

let temp_file prefix suffix =
  let filename = Filename.temp_file prefix suffix in
  temp_filenames := filename :: !temp_filenames;
  filename

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
      Mach_log.log_very_verbose "mach:watch: event: %s" line;
      (match parse_event line with
      | None -> ()
      | Some (_event_type, path) -> Hashtbl.replace paths path ());
      loop ()
    end
  in
  loop ()

let watch config target ?run_args () =
  let exception Restart_watcher in
  let code = Sys.command "command -v watchexec > /dev/null 2>&1" in
  if code <> 0 then begin
    Printf.eprintf "mach: watchexec not found. Install it: https://github.com/watchexec/watchexec\n%!";
    exit 1
  end;

  (* Track current state for signal handling and cleanup *)
  let current_process = ref None in
  let current_watchlist = ref None in
  let child_pid : int option ref = ref None in

  let kill_child () =
    match !child_pid with
    | None -> ()
    | Some pid ->
      (match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ ->
        Mach_log.log_verbose "mach: stopping previous instance (pid %d)..." pid;
        Unix.kill pid Sys.sigterm;
        ignore (Unix.waitpid [] pid)
      | _ -> ());
      child_pid := None
  in

  let start_child () =
    match run_args, target with
    | None, _ -> ()
    | Some _, Mach_lib.Target_library _ ->
      Printf.eprintf "mach: cannot run a library, use 'mach build' instead\n%!";
      exit 1
    | Some args, Mach_lib.Target_executable script_path ->
      kill_child ();
      let exe_path = Filename.(Mach_config.build_dir_of config script_path / "a.out") in
      let argv = Array.of_list (exe_path :: args) in
      Mach_log.log_verbose "mach: starting %s" script_path;
      let pid = Unix.create_process exe_path argv Unix.stdin Unix.stdout Unix.stderr in
      child_pid := Some pid
  in

  let cleanup () =
    kill_child ();
    !current_process |> Option.iter (fun (pid, ic) ->
      begin try close_in ic with _ -> () end;
      (match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ -> Unix.kill pid Sys.sigterm; ignore (Unix.waitpid [] pid)
      | _ -> ());
      current_process := None);
    !current_watchlist |> Option.iter (fun path ->
      begin try Sys.remove path with _ -> () end;
      current_watchlist := None)
  in

  Sys.(set_signal sigint (Signal_handle (fun _ -> cleanup (); exit 0)));

  Mach_log.log_verbose "mach: initial build...";
  (* Don't exit on initial build failure - continue watching for changes *)
  (match build config target with
  | Ok _target -> start_child ()
  | Error (`User_error msg) -> Mach_log.log_verbose "mach: %s" msg);

  let keep_watching = ref true in
  while !keep_watching do
    let _reconfigured, mods, libs = configure config target |> or_exit in
    let source_dirs = SS.empty in
    let source_dirs = List.fold_left (fun acc (m : Mach_module.t) ->
      SS.add (Filename.dirname m.path_ml) acc
    ) source_dirs mods in
    let source_dirs = List.fold_left (fun acc (lib : Mach_library.t) ->
      SS.add lib.path acc
    ) source_dirs libs in
    let source_dirs = SS.elements source_dirs in
    let source_files =
      let files = Hashtbl.create 16 in
      let add file = Hashtbl.replace files file () in
      mods |> List.iter (fun (m : Mach_module.t) ->
        add m.path_ml; Option.iter (fun mli -> add mli) m.path_mli);
      files
    in
    let lib_dirs =
      let dirs = Hashtbl.create 16 in
      let add file = Hashtbl.replace dirs file () in
      libs |> List.iter (fun (lib : Mach_library.t) -> add lib.path);
      dirs
    in
    Mach_log.log_verbose "mach: watching %d directories (Ctrl+C to stop):" (List.length source_dirs);
    List.iter (fun d -> Mach_log.log_verbose "  %s" d) source_dirs;
    let watchlist_path =
      let path = temp_file "mach-watch" ".txt" in
      Out_channel.with_open_text path (fun oc ->
        List.iter (fun dir ->
          output_string oc "-W\n";
          output_string oc dir;
          output_char oc '\n'
        ) source_dirs);
      path
    in
    current_watchlist := Some watchlist_path;
    let args = [|
      "watchexec";
      "--debounce"; "200ms";
      "--only-emit-events";
      "--emit-events-to=stdio";
      "@" ^ watchlist_path
    |] in
    Mach_log.log_very_verbose "mach:watch: running: %s" (String.concat " " (Array.to_list args));
    let pipe_read, pipe_write = Unix.pipe () in
    let pid = Unix.create_process "watchexec" args Unix.stdin pipe_write Unix.stderr in
    Unix.close pipe_write;
    let ic = Unix.in_channel_of_descr pipe_read in
    current_process := Some (pid, ic);

    begin try
      while true do
        let changed_paths = read_events ic in
        let relevant_paths =
          List.fold_left (fun acc path ->
            if Hashtbl.mem source_files path
            then path :: acc
            else if Hashtbl.mem lib_dirs (Filename.dirname path)
            then path :: acc
            else acc
          ) [] changed_paths
        in
        if relevant_paths <> [] then begin
          List.iter (fun p -> Mach_log.log_verbose "mach: file changed: %s" (Filename.basename p)) relevant_paths;
          match build config target with
          | Error (`User_error msg) -> Mach_log.log_verbose "mach: %s" msg
          | Ok (_target, reconfigured, _, _) ->
            Printf.eprintf "mach: build succeeded\n%!";
            start_child ();
            if reconfigured then begin
              Mach_log.log_verbose "mach:watch: reconfigured, restarting watcher...";
              raise_notrace Restart_watcher
            end
        end
      done
    with
    | Restart_watcher -> cleanup ()
    | End_of_file -> cleanup (); keep_watching := false
    end
  done

(* --- Command Line --- *)

open Cmdliner

let verbose_arg =
  let f verbose =
    let verbose =
      match verbose with [] -> Quiet | [_] -> Verbose | _::_::[] -> Very_verbose | _ -> Very_very_verbose
    in
    Mach_log.verbose := verbose
  in
  Term.(
    const f
    $ Arg.(value & flag_all & info ["v"; "verbose"] ~doc:"Log external command invocations to stderr."))

let target_arg =
  Arg.(required & pos 0 (some file) None & info [] ~docv:"SCRIPT" ~doc:"OCaml script or library to build")

let args_arg =
  Arg.(value & pos_right 0 string [] & info [] ~docv:"ARGS" ~doc:"Arguments to pass to the script")

let watch_arg =
  Arg.(value & flag & info ["w"; "watch"]
    ~doc:"Watch for changes and rebuild automatically. Requires watchexec to be installed.")

let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  let f () watch_mode script_path args =
    let config = Mach_config.get () |> or_exit in
    let target = Mach_lib.resolve_target config script_path in
    begin match target with
    | Mach_lib.Target_library _ ->
      Printf.eprintf "mach: cannot run a library, use 'mach build' instead\n%!";
      exit 1
    | Mach_lib.Target_executable _ -> ()
    end;
    if watch_mode then watch config target ~run_args:args ()
    else begin
      let exe_path, _reconfigured, _, _ = build config target |> or_exit in
      let argv = Array.of_list (exe_path :: args) in
      Unix.execv exe_path argv
    end
  in
  Cmd.v info Term.(const f $ verbose_arg $ watch_arg $ target_arg $ args_arg)

let build_cmd =
  let doc = "Build an OCaml script or library without executing it" in
  let info = Cmd.info "build" ~doc in
  let f () watch_mode script_path =
    let config = Mach_config.get () |> or_exit in
    let target = Mach_lib.resolve_target config script_path in
    if watch_mode then watch config target ()
    else build config target |> or_exit |> ignore
  in
  Cmd.v info Term.(const f $ verbose_arg $ watch_arg $ target_arg)

let source_arg =
  Arg.(required & pos 0 (some file) None & info [] ~docv:"SOURCE" ~doc:"OCaml source file or library to configure")

let configure_cmd =
  let doc = "Generate build files for all modules in dependency graph" in
  let info = Cmd.info "configure" ~doc ~docs:Manpage.s_none in
  let f path =
    let config = Mach_config.get () |> or_exit in
    let target = Mach_lib.resolve_target config path in
    configure config target |> or_exit |> ignore
  in
  Cmd.v info Term.(const f $ source_arg)

let pp_cmd =
  let doc = "Preprocess source file to stdout (for use with merlin -pp)" in
  let f source output pp_cmd =
    let with_output f =
      match output with
      | Some o ->
        let temp = temp_file "mach-pp" ".ml" in
        Out_channel.with_open_text temp f;
        Sys.rename temp o
      | None -> f stdout
    in
    let mach_pp oc =
      In_channel.with_open_text source (fun ic -> pp ~source_path:source ic oc)
    in
    let ext_pp input_file cmd =
      let cmd = Printf.sprintf "%s %s" cmd (Filename.quote input_file) in
      let full_cmd = match output with
        | None -> cmd
        | Some out ->
          let temp = temp_file "mach-pp" ".ml" in
          Printf.sprintf "%s > %s && mv %s %s" cmd (Filename.quote temp) (Filename.quote temp) (Filename.quote out)
      in
      let code = Sys.command full_cmd in
      if code <> 0 then begin
        Printf.eprintf "mach: preprocessor %S failed\n%!" cmd;
        exit 1
      end
    in
    match pp_cmd with
    | None ->
      with_output mach_pp
    | Some cmd ->
      let temp = temp_file "mach-pp" ".ml" in
      Out_channel.with_open_text temp mach_pp;
      ext_pp temp cmd
  in
  Cmd.v
    Cmd.(info "pp" ~doc ~docs:Manpage.s_none)
    Term.(
      const f
      $ source_arg
      $ Arg.(value & opt (some string) None & info ["o"; "output"] ~docv:"FILE" ~doc:"Write output to FILE instead of stdout")
      $ Arg.(value & opt (some string) None & info ["pp"] ~docv:"COMMAND" ~doc:"External preprocessor to run after mach preprocessing"))

let run_build_command_cmd =
  let doc = "Run a build command, prefixing output with >>>" in
  let info = Cmd.info "run-build-command" ~doc ~docs:Manpage.s_none in
  let cmd_arg = Arg.(non_empty & pos_all string [] & info [] ~docv:"COMMAND") in
  let stderr_only_arg = Arg.(value & flag & info ["stderr-only"] ~doc:"Only capture stderr, let stdout pass through") in
  let f stderr_only args =
    let open Unix in
    let prog, argv = match args with
      | [] -> prerr_endline "mach run-build-command: no command"; exit 1
      | prog :: _ -> prog, Array.of_list args
    in
    let (pipe_read, pipe_write) = pipe () in
    let pid = match fork () with
      | 0 ->
        close pipe_read;
        if not stderr_only then dup2 pipe_write stdout;
        dup2 pipe_write stderr;
        close pipe_write;
        execvp prog argv
      | pid -> pid
    in
    close pipe_write;
    let ic = in_channel_of_descr pipe_read in
    (try while true do
      let line = input_line ic in
      Printf.eprintf ">>>%s\n%!" line
    done with End_of_file -> ());
    close_in ic;
    let _, status = waitpid [] pid in
    match status with
    | WEXITED code -> exit code
    | WSIGNALED n -> exit (128 + n)
    | WSTOPPED _ -> exit 1
  in
  Cmd.v info Term.(const f $ stderr_only_arg $ cmd_arg)

let dep_cmd =
  let doc = "Run ocamldep and output ninja dyndep format" in
  let f input output args =
    let parse_dep_line line =
      match String.index_opt line ':' with
      | None -> None
      | Some colon_pos ->
        let target = String.trim (String.sub line 0 colon_pos) in
        let deps = String.sub line (colon_pos + 1) (String.length line - colon_pos - 1) in
        let deps =
          String.split_on_char ' ' deps
          |> List.filter (fun s -> String.length (String.trim s) > 0)
          |> List.map String.trim
        in
        Some (target, deps)
    in
    let deps =
      let args_flag = match args with None -> "" | Some f -> " -args " ^ Filename.quote f in
      let cmd = Printf.sprintf "ocamldep -native -one-line%s %s" args_flag (Filename.quote input) in
      let ic = Unix.open_process_in cmd in
      let lines = In_channel.input_lines ic in
      if Unix.close_process_in ic <> Unix.WEXITED 0 then (
        Printf.eprintf "mach dep: ocamldep failed\n%!"; exit 1);
      List.filter_map parse_dep_line lines
    in
    let tmp = temp_file "mach-dep" ".dep" in
    let build_dir = Filename.dirname (Unix.realpath input) in
    Out_channel.with_open_text tmp (fun oc ->
      Printf.fprintf oc "ninja_dyndep_version = 1\n";
      let norm_path path = if Filename.is_relative path then Filename.(build_dir / path) else path in
      List.iter (fun (target, deps) ->
        let target = norm_path target in
        let deps = List.map norm_path deps in
        if deps = []
        then Printf.fprintf oc "build %s: dyndep\n" target
        else Printf.fprintf oc "build %s: dyndep | %s\n" target (String.concat " " deps)
      ) deps);
    Sys.rename tmp output
  in
  Cmd.v (Cmd.info "dep" ~doc ~docs:Manpage.s_none)
    Term.(const f
      $ Arg.(required & pos 0 (some non_dir_file) None & info [] ~docv:"FILE" ~doc:"Source file to analyze")
      $ Arg.(required & opt (some string) None & info ["o"; "output"] ~docv:"FILE" ~doc:"Output file for dyndep")
      $ Arg.(value & opt (some string) None & info ["args"] ~docv:"FILE" ~doc:"Args file to pass to ocamldep"))

let link_deps_cmd =
  let doc = "Read .dep files and output sorted .cmx files for linking" in
  let f dep_files =
    (* Parse a .dep file to get (target, deps) *)
    let parse_dep_file path =
      let lines = In_channel.with_open_text path In_channel.input_lines in
      List.filter_map (fun line ->
        (* Format: "build foo.cmx: dyndep | bar.cmx baz.cmx" or "build foo.cmx: dyndep" *)
        if String.length line > 6 && String.sub line 0 6 = "build " then
          match String.index_opt line ':' with
          | None -> None
          | Some colon ->
            let target = String.trim (String.sub line 6 (colon - 6)) in
            let rest = String.sub line (colon + 1) (String.length line - colon - 1) in
            let deps = match String.index_opt rest '|' with
              | None -> []
              | Some pipe ->
                String.sub rest (pipe + 1) (String.length rest - pipe - 1)
                |> String.split_on_char ' '
                |> List.filter (fun s -> String.length (String.trim s) > 0)
                |> List.map String.trim
            in
            Some (target, deps)
        else None
      ) lines
    in
    (* Build dependency graph from all .dep files *)
    let graph = Hashtbl.create 16 in
    List.iter (fun dep_file ->
      List.iter (fun (target, deps) ->
        Hashtbl.replace graph target deps
      ) (parse_dep_file dep_file)
    ) dep_files;
    (* Topological sort *)
    let visited = Hashtbl.create 16 in
    let result = ref [] in
    let rec visit node =
      if not (Hashtbl.mem visited node) then begin
        Hashtbl.add visited node ();
        List.iter visit (Hashtbl.find_opt graph node |> Option.value ~default:[]);
        result := node :: !result
      end
    in
    Hashtbl.iter (fun node _ -> visit node) graph;
    (* Output sorted list, one per line for use with -args *)
    List.iter print_endline (List.rev !result)
  in
  Cmd.v (Cmd.info "link-deps" ~doc ~docs:Manpage.s_none)
    Term.(const f
      $ Arg.(non_empty & pos_all non_dir_file [] & info [] ~docv:"DEP_FILES" ~doc:".dep files to process"))

let cmd =
  let doc = "Run OCaml scripts with automatic dependency resolution" in
  let info = Cmd.info "mach" ~doc ~man:[`S Manpage.s_synopsis] in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group ~default info [run_cmd; build_cmd; configure_cmd; pp_cmd; run_build_command_cmd; dep_cmd; link_deps_cmd]

let () = exit (Cmdliner.Cmd.eval cmd)
