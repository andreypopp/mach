(* mach - OCaml scripting runtime *)

open Mach_lib

let or_exit = function
  | Ok v -> v
  | Error (`User_error msg) ->
    Printf.eprintf "mach: %s\n%!" msg;
    exit 1

let run verbose script_path args =
  Mach_log.verbose := verbose;
  let config = Mach_config.get () |> or_exit in
  let ~state, ~reconfigured:_ = build config script_path |> or_exit in
  let exe_path = Mach_state.exe_path config state in
  let argv = Array.of_list (exe_path :: args) in
  Unix.execv exe_path argv

(* --- Command Line --- *)

open Cmdliner

let verbose_arg =
  Term.(
    const (function [] -> Quiet | [_] -> Verbose | _::_::[] -> Very_verbose | _ -> Very_very_verbose)
    $ Arg.(value & flag_all & info ["v"; "verbose"] ~doc:"Log external command invocations to stderr."))

let script_arg =
  Arg.(required & pos 0 (some non_dir_file) None & info [] ~docv:"SCRIPT" ~doc:"OCaml script to run")

let args_arg =
  Arg.(value & pos_right 0 string [] & info [] ~docv:"ARGS" ~doc:"Arguments to pass to the script")

let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run $ verbose_arg $ script_arg $ args_arg)

let watch_arg =
  Arg.(value & flag & info ["w"; "watch"]
    ~doc:"Watch for changes and rebuild automatically. Requires watchexec to be installed.")

let build_cmd =
  let doc = "Build an OCaml script without executing it" in
  let info = Cmd.info "build" ~doc in
  let f verbose watch script_path =
    Mach_log.verbose := verbose;
    let config = Mach_config.get () |> or_exit in
    if watch then Mach_lib.watch config script_path |> or_exit
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
