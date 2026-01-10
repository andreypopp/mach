(* mach - OCaml scripting runtime *)

open Mach_lib

let run build_backend verbose script_path args =
  Mach_lib.verbose := verbose;
  let ~state, ~reconfigured:_ = build ~build_backend script_path in
  let exe_path = Mach_state.exe_path state in
  let argv = Array.of_list (exe_path :: args) in
  Unix.execv exe_path argv

(* --- Command Line --- *)

open Cmdliner

let verbose_arg =
  Term.(
    const (function [] -> Quiet | [_] -> Verbose | _::_::[] -> Very_verbose | _ -> Very_very_verbose)
    $ Arg.(value & flag_all & info ["v"; "verbose"] ~doc:"Log external command invocations to stderr."))

let build_backend_arg =
  let doc = "Build backend to use: 'make' (default) or 'ninja'. \
             Can also be set via MACH_BUILD_BACKEND environment variable." in
  let env = Cmd.Env.info "MACH_BUILD_BACKEND" in
  Arg.(value & opt (enum ["make", Make; "ninja", Ninja]) Make & info ["build-backend"] ~env ~doc)

let script_arg =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"SCRIPT" ~doc:"OCaml script to run")

let args_arg =
  Arg.(value & pos_right 0 string [] & info [] ~docv:"ARGS" ~doc:"Arguments to pass to the script")

let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run $ build_backend_arg $ verbose_arg $ script_arg $ args_arg)

let watch_arg =
  Arg.(value & flag & info ["w"; "watch"]
    ~doc:"Watch for changes and rebuild automatically. Requires watchexec to be installed.")

let build_cmd =
  let doc = "Build an OCaml script without executing it" in
  let info = Cmd.info "build" ~doc in
  let f build_backend verbose watch script_path =
    Mach_lib.verbose := verbose;
    if watch then
      Mach_lib.watch ~build_backend script_path
    else
      ignore (build ~build_backend script_path : state:Mach_state.t * reconfigured:bool)
  in
  Cmd.v info Term.(const f $ build_backend_arg $ verbose_arg $ watch_arg $ script_arg)

let output_dir_arg =
  Arg.(required & opt (some string) None & info ["o"; "output"] ~docv:"DIR"
    ~doc:"Output directory for generated files. If not specified, uses default build directory.")

let source_arg =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"SOURCE" ~doc:"OCaml source file to configure")

let preprocess_cmd =
  let doc = "Preprocess a module and generate build files" in
  let info = Cmd.info "preprocess" ~doc in
  Cmd.v info Term.(const preprocess $ output_dir_arg $ source_arg)

let configure_cmd =
  let doc = "Generate build files for all modules in dependency graph" in
  let info = Cmd.info "configure" ~doc in
  let f build_backend path = ignore (configure ~build_backend path : (state:Mach_state.t * reconfigured:bool)) in
  Cmd.v info Term.(const f $ build_backend_arg $ source_arg)

let pp_cmd =
  let doc = "Preprocess source file to stdout (for use with merlin -pp)" in
  let info = Cmd.info "pp" ~doc in
  Cmd.v info Term.(const pp $ source_arg)

let cmd =
  let doc = "Run OCaml scripts with automatic dependency resolution" in
  let info = Cmd.info "mach" ~doc in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group ~default info [run_cmd; build_cmd; preprocess_cmd; configure_cmd; pp_cmd]

let () = exit (Cmdliner.Cmd.eval cmd)
