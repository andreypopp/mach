# Plan: Add `--watch` to `mach run` command

## Summary

Add `--watch/-w` flag to `mach run` that watches for file changes, rebuilds, and restarts the program.

## File to modify

`/Users/andreypopp/Workspace/rrun/bin/mach.ml`

## Implementation Steps

### Step 1: Extend `watch` function signature (line 44)

Change from:
```ocaml
let watch config script_path =
```

To:
```ocaml
let watch config script_path ?run_args =
```

When `run_args` is:
- `None` → build-only watch (current behavior)
- `Some args` → run mode: start/restart program after each successful build

### Step 2: Add process management inside `watch` (after line 62)

Add child process tracking and helpers:

```ocaml
let child_pid : int option ref = ref None in

let kill_child () =
  match !child_pid with
  | None -> ()
  | Some pid ->
    (match Unix.waitpid [WNOHANG] pid with
    | 0, _ ->  (* Still running *)
      Mach_log.log_verbose "mach: stopping previous instance (pid %d)..." pid;
      Unix.kill pid Sys.sigterm;
      ignore (Unix.waitpid [] pid)
    | _ -> ());  (* Already exited *)
    child_pid := None
in

let start_child state =
  match run_args with
  | None -> ()
  | Some args ->
    kill_child ();
    let exe_path = Mach_state.exe_path config state in
    let argv = Array.of_list (exe_path :: args) in
    Mach_log.log_verbose "mach: starting %s" exe_path;
    let pid = Unix.create_process exe_path argv Unix.stdin Unix.stdout Unix.stderr in
    child_pid := Some pid
in
```

### Step 3: Update cleanup function (line 64)

Add `kill_child ()` call in cleanup:

```ocaml
let cleanup () =
  kill_child ();  (* NEW: kill child process if running *)
  !current_process |> Option.iter ...
```

### Step 4: Call `start_child` on successful builds

On initial build success (line 57):
```ocaml
| Ok (~state, ~reconfigured:_) -> start_child state
```

On rebuild success (line 118):
```ocaml
| Ok (~state, ~reconfigured) ->
  Printf.eprintf "mach: build succeeded\n%!";
  start_child state;
  if reconfigured then ...
```

### Step 5: Modify `run_cmd` (lines 153-156)

Add `watch_arg` and dispatch:

```ocaml
let run_cmd =
  let doc = "Run an OCaml script" in
  let info = Cmd.info "run" ~doc in
  let f () watch_mode script_path args =
    let config = Mach_config.get () |> or_exit in
    if watch_mode then watch config script_path ~run_args:args
    else begin
      let ~state, ~reconfigured:_ = build config script_path |> or_exit in
      let exe_path = Mach_state.exe_path config state in
      let argv = Array.of_list (exe_path :: args) in
      Unix.execv exe_path argv
    end
  in
  Cmd.v info Term.(const f $ verbose_arg $ watch_arg $ script_arg $ args_arg)
```

### Step 6: Remove standalone `run` function (lines 11-16)

The logic is now inlined in `run_cmd`.

## Testing

Create `/Users/andreypopp/Workspace/rrun/test/test_run_watch.t` with tests for:
1. Long-lived program: verify it gets killed and restarted on rebuild
2. Short-lived program: verify new version runs after rebuild
3. Build failure: verify error is printed and watch continues
