(* mach - OCaml scripting runtime *)

open Mach_lib

let or_exit = function
  | Ok v -> v
  | Error (`User_error msg) ->
    Printf.eprintf "mach: %s\n%!" msg;
    exit 1

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

let watch config script_path ?run_args () =
  let build_dir_of = Mach_config.build_dir_of config in
  let exception Restart_watcher in
  let code = Sys.command "command -v watchexec > /dev/null 2>&1" in
  if code <> 0 then begin
    Printf.eprintf "mach: watchexec not found. Install it: https://github.com/watchexec/watchexec\n%!";
    exit 1
  end;
  let script_path = Unix.realpath script_path in

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

  let start_child state =
    match run_args with
    | None -> ()
    | Some args ->
      kill_child ();
      let exe_path = Mach_state.exe_path config state in
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
  (match build config script_path with
  | Ok (~state, ~reconfigured:_) -> start_child state
  | Error (`User_error msg) -> Mach_log.log_verbose "mach: %s" msg);

  let keep_watching = ref true in
  while !keep_watching do
    let state = Option.get (Mach_state.read (Filename.concat (build_dir_of script_path) "Mach.state")) in
    let source_dirs = Mach_state.source_dirs state in
    let source_files =
      let files = Hashtbl.create 16 in
      List.iter (fun (entry : Mach_state.entry) ->
        Hashtbl.replace files entry.ml_path ();
        Option.iter (fun mli -> Hashtbl.replace files mli ()) entry.mli_path
      ) state.entries;
      files
    in
    Mach_log.log_verbose "mach: watching %d directories (Ctrl+C to stop):" (List.length source_dirs);
    List.iter (fun d -> Mach_log.log_verbose "  %s" d) source_dirs;
    let watchlist_path =
      let path = Filename.temp_file "mach-watch" ".txt" in
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
      "--exts"; "ml,mli,mlx";
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
          List.fold_left (fun acc path -> if Hashtbl.mem source_files path then path :: acc else acc)
          [] changed_paths
        in
        if relevant_paths <> [] then begin
          List.iter (fun p -> Mach_log.log_verbose "mach: file changed: %s" (Filename.basename p)) relevant_paths;
          match build config script_path with
          | Error (`User_error msg) -> Mach_log.log_verbose "mach: %s" msg
          | Ok (~state, ~reconfigured) ->
            Printf.eprintf "mach: build succeeded\n%!";
            start_child state;
            if reconfigured then begin
              Mach_log.log_verbose "mach:watch: reconfigured, restarting watcher...";
              raise Restart_watcher
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

let script_arg =
  Arg.(required & pos 0 (some non_dir_file) None & info [] ~docv:"SCRIPT" ~doc:"OCaml script to run")

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
    if watch_mode then watch config script_path ~run_args:args ()
    else begin
      let ~state, ~reconfigured:_ = build config script_path |> or_exit in
      let exe_path = Mach_state.exe_path config state in
      let argv = Array.of_list (exe_path :: args) in
      Unix.execv exe_path argv
    end
  in
  Cmd.v info Term.(const f $ verbose_arg $ watch_arg $ script_arg $ args_arg)

let build_cmd =
  let doc = "Build an OCaml script without executing it" in
  let info = Cmd.info "build" ~doc in
  let f () watch_mode script_path =
    let config = Mach_config.get () |> or_exit in
    if watch_mode then watch config script_path ()
    else build config script_path |> or_exit |> ignore
  in
  Cmd.v info Term.(const f $ verbose_arg $ watch_arg $ script_arg)

let source_arg =
  Arg.(required & pos 0 (some non_dir_file) None & info [] ~docv:"SOURCE" ~doc:"OCaml source file to configure")

let configure_cmd =
  let doc = "Generate build files for all modules in dependency graph" in
  let info = Cmd.info "configure" ~doc ~docs:Manpage.s_none in
  let f path =
    let config = Mach_config.get () |> or_exit in
    configure config path |> or_exit |> ignore
  in
  Cmd.v info Term.(const f $ source_arg)

let pp_cmd =
  let doc = "Preprocess source file to stdout (for use with merlin -pp)" in
  let info = Cmd.info "pp" ~doc ~docs:Manpage.s_none in
  Cmd.v info Term.(const pp $ source_arg)

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

let cmd =
  let doc = "Run OCaml scripts with automatic dependency resolution" in
  let info = Cmd.info "mach" ~doc ~man:[`S Manpage.s_synopsis] in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group ~default info [run_cmd; build_cmd; configure_cmd; pp_cmd; run_build_command_cmd]

let () = exit (Cmdliner.Cmd.eval cmd)
