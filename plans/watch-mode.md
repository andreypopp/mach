# Watch Mode Implementation Plan

## Overview

Add a `--watch` option to `mach build SCRIPT.ml` that continuously monitors source files for changes and rebuilds automatically using `watchexec`.

## Design

### High-Level Flow

1. When `--watch` is passed to `mach build`:
   - Check if `watchexec` is installed (error with helpful message if not)
   - Run initial configure to get the dependency graph (`Mach_state.t`)
   - Extract all source directories from the state
   - Start `watchexec` process watching those directories
   - Read watchexec output line by line
   - For each file change event, check if the file is in the dependency graph
   - If yes, re-run configure (if needed, also need to restart `watchexec` if set of dirs changed) and build

### watchexec Invocation

Based on the manual research, we'll use:
```
watchexec \
  --only-emit-events \      # Just emit events, no command
  --emit-events-to=stdio \  # Output events as text to stdout (format: "modify:/path/to/file", also "create:", "remove:", "rename:")
  --stdin-quit \            # Exit when stdin is closed
  -e ml,mli \               # Only watch .ml and .mli files
  @/tmp/watchlist.txt       # Read additional args from argfile
```

The argfile is written to a temp location (e.g., `/tmp/mach-watchXXXXXX.txt`) containing `-W <dir>` lines (one per directory, non-recursive watch).

### Event Format (stdio mode)

When using `--emit-events-to=stdio`, events look like:
```
modify:/absolute/path/to/file.ml
create:/absolute/path/to/new.ml
remove:/absolute/path/to/deleted.ml
rename:/absolute/path/to/renamed.ml
```

### Source Directory Extraction

From `Mach_state.t`, we can get all source files:
- `state.entries` contains all modules
- Each entry has `ml_path` and optionally `mli_path`
- Extract unique directories using `Filename.dirname` on these paths
- Need to deduplicate directories

### Handling Dynamic Dependency Changes

When a file changes:
1. If it's in the current dependency graph, run configure (which handles staleness checking)
2. If configure detects requires changed, it will rebuild the dependency graph
3. If reconfiguration happened, restart watchexec (simpler than tracking directory changes)

### Code Changes

#### 1. lib/mach_lib.ml

**Modify `configure` and `build` to return whether reconfiguration happened:**

- `configure`: Change return type from `Mach_state.t * ocaml_module * string` to `(Mach_state.t * bool) * ocaml_module * string` where the bool indicates if reconfiguration was needed. The `needs_reconfig` value already exists in the function - just include it in the return tuple.
- `build`: Change return type from `string` to `string * bool` (exe_path, reconfigured). Extract the bool from configure's return value and propagate it.

**Add new section `(* --- Watch mode --- *)` after the Build section:**

```ocaml
(* --- Watch mode --- *)

let check_watchexec_installed () =
  let code = Sys.command "command -v watchexec > /dev/null 2>&1" in
  if code <> 0 then
    failwith "watchexec not found. Install it: https://github.com/watchexec/watchexec"

(* Extract unique directories from all source files in the state, sorted for determinism *)
let source_dirs_of_state (state : Mach_state.t) : string list =
  let seen = Hashtbl.create 16 in
  let add_dir path =
    let dir = Filename.dirname path in
    Hashtbl.replace seen dir ()
  in
  List.iter (fun (entry : Mach_state.entry) ->
    add_dir entry.ml_path;
    Option.iter add_dir entry.mli_path
  ) state.entries;
  Hashtbl.fold (fun dir () acc -> dir :: acc) seen []
  |> List.sort String.compare

(* Parse watchexec stdio event line *)
let parse_watch_event line =
  match String.index_opt line ':' with
  | None -> None
  | Some i ->
    let event_type = String.sub line 0 i in
    let path = String.sub line (i + 1) (String.length line - i - 1) in
    Some (event_type, path)

(* Build a set of all source files in the state for O(1) lookup *)
let source_files_of_state (state : Mach_state.t) : (string, unit) Hashtbl.t =
  let files = Hashtbl.create 16 in
  List.iter (fun (entry : Mach_state.entry) ->
    Hashtbl.replace files entry.ml_path ();
    Option.iter (fun mli -> Hashtbl.replace files mli ()) entry.mli_path
  ) state.entries;
  files

(* Write directories to a temp file for watchexec @argfile syntax *)
let write_watchlist dirs =
  let path = Filename.temp_file "mach-watch" ".txt" in
  Out_channel.with_open_text path (fun oc ->
    List.iter (fun dir -> output_line oc ("-W " ^ dir)) dirs);
  path

(* Exception used to signal watcher restart *)
exception Restart_watcher

let watch ?(build_backend=Make) script_path =
  check_watchexec_installed ();
  let script_path = Unix.realpath script_path in

  (* Initial build *)
  log_verbose "mach: initial build...";
  let _, _ = build ~build_backend script_path in

  (* Get initial state and directories *)
  let state_path = Filename.(build_dir_of script_path / "Mach.state") in

  (* Track current state for signal handling and cleanup *)
  let current_process = ref None in
  let current_watchlist = ref None in

  let cleanup () =
    (match !current_process with
    | Some (ic, oc) ->
      (try close_out oc with _ -> ());  (* Close stdin to trigger --stdin-quit *)
      (try ignore (Unix.close_process (ic, oc)) with _ -> ());
      current_process := None
    | None -> ());
    (match !current_watchlist with
    | Some path -> (try Sys.remove path with _ -> ()); current_watchlist := None
    | None -> ())
  in

  (* Install signal handler for clean shutdown on Ctrl+C *)
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    cleanup ();
    exit 0
  ));

  (* Main watch loop - uses while loop to avoid stack overflow on restarts *)
  let keep_watching = ref true in
  while !keep_watching do
    let state = Option.get (Mach_state.read state_path) in
    let source_files = source_files_of_state state in
    let source_dirs = source_dirs_of_state state in

    (* Print watched directories *)
    log_verbose "mach: watching %d directories (Ctrl+C to stop):" (List.length source_dirs);
    List.iter (fun d -> log_verbose "  %s" d) source_dirs;

    let watchlist_path = write_watchlist source_dirs in
    current_watchlist := Some watchlist_path;
    let cmd = sprintf "watchexec --only-emit-events --emit-events-to=stdio --stdin-quit -e ml,mli @%s" (Filename.quote watchlist_path) in
    log_very_verbose "mach:watch: running: %s" cmd;

    (* Use open_process to get control over stdin for --stdin-quit *)
    let (ic, oc) = Unix.open_process cmd in
    current_process := Some (ic, oc);

    begin try
      while true do
        let line = input_line ic in
        log_very_verbose "mach:watch: event: %s" line;
        match parse_watch_event line with
        | None -> ()
        | Some (_event_type, path) ->
          if Hashtbl.mem source_files path then begin
            log_verbose "mach: file changed: %s" (Filename.basename path);
            begin try
              let _, reconfigured = build ~build_backend script_path in
              log_verbose "mach: build succeeded";
              if reconfigured then begin
                log_verbose "mach:watch: reconfigured, restarting watcher...";
                raise Restart_watcher
              end
            with
            | Restart_watcher -> raise Restart_watcher  (* Re-raise *)
            | Failure msg -> log_verbose "mach: build failed: %s" msg
            | exn -> log_verbose "mach: build error: %s" (Printexc.to_string exn)
            end
          end
      done
    with
    | Restart_watcher ->
      close_out oc;  (* Close stdin to trigger --stdin-quit *)
      ignore (Unix.close_process (ic, oc));
      current_process := None;
      Sys.remove watchlist_path;
      current_watchlist := None
      (* Loop continues, will restart watchexec *)
    | End_of_file ->
      ignore (Unix.close_process (ic, oc));
      current_process := None;
      Sys.remove watchlist_path;
      current_watchlist := None;
      keep_watching := false  (* watchexec exited, stop watching *)
    end
  done
```

#### 2. bin/mach.ml

Add `--watch` flag to the build command:

```ocaml
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
      ignore (build ~build_backend script_path : string * bool)
  in
  Cmd.v info Term.(const f $ build_backend_arg $ verbose_arg $ watch_arg $ script_arg)
```

**Also update the `run` function to handle new return type:**

```ocaml
let run build_backend verbose script_path args =
  Mach_lib.verbose := verbose;
  let exe_path, _ = build ~build_backend script_path in
  let argv = Array.of_list (exe_path :: args) in
  Unix.execv exe_path argv
```

**And update `configure_cmd`:**

```ocaml
let configure_cmd =
  let doc = "Generate build files for all modules in dependency graph" in
  let info = Cmd.info "configure" ~doc in
  let f build_backend path = ignore (configure ~build_backend path : (Mach_state.t * bool) * _ * _) in
  Cmd.v info Term.(const f $ build_backend_arg $ source_arg)
```

### Edge Cases

1. **watchexec not installed**: Clear error message with installation instructions
2. **File added to dependency graph**: After rebuild, check if source_dirs changed and restart watchexec
3. **File removed from dependency graph**: Same as above - handled by restart
4. **Rapid successive changes**: watchexec's debounce (default 50ms) handles this
5. **Build failure**: Catch `Failure` and other exceptions, print error, continue watching
6. **Ctrl+C**: Custom SIGINT handler ensures clean shutdown - closes watchexec's stdin (triggering `--stdin-quit`), cleans up temp files, then exits cleanly
7. **Temp file cleanup**: Watchlist temp files tracked in `current_watchlist` ref and cleaned up on restart, exit, and SIGINT

### Testing

Create a new test file `test/test_watch.t`:

```
  $ source ../env.sh

Prepare source files:
  $ cat << 'EOF' > hello.ml
  > print_endline "hello"
  > EOF

Test that --watch requires watchexec (if not installed, skip):
  $ if command -v watchexec > /dev/null 2>&1; then
  >   echo "watchexec installed, testing watch mode..."
  >   # Start watch in background with verbose flag, modify file, check output
  >   timeout 3s mach build -v --watch ./hello.ml &
  >   sleep 1
  >   echo 'print_endline "updated"' > hello.ml
  >   sleep 1
  > else
  >   echo "watchexec not installed, skipping watch test"
  > fi
  watchexec installed, testing watch mode...
  mach: initial build...
  mach: watching for changes (Ctrl+C to stop)...
  mach: file changed: hello.ml
  mach: build succeeded
  [... or appropriate skip message]
```

Note: Testing watch mode is inherently tricky due to timing. We may want to keep the test simple or skip it in CI if watchexec isn't available.

### Alternative Considerations

1. **Recursive vs non-recursive watching**: Using `-W` (non-recursive) to watch only the specific directories containing source files. Could use `-w` (recursive) for simpler setup but would watch more than needed.

2. **Using JSON event format**: Could use `--emit-events-to=json-stdio` for more structured event data, but the simple text format is sufficient for our needs.

## Implementation Steps

1. Modify `configure` to return `(Mach_state.t * bool) * ocaml_module * string` (bool = reconfigured)
2. Modify `build` to return `string * bool` (exe_path, reconfigured)
3. Update all call sites in `bin/mach.ml` for new return types (`run`, `build_cmd`, `configure_cmd`)
4. Add `check_watchexec_installed` function (uses `command -v` for POSIX compatibility)
5. Add `source_dirs_of_state` function (uses Hashtbl for dedup)
6. Add `source_files_of_state` function (builds Hashtbl for O(1) lookup)
7. Add `parse_watch_event` function
8. Add `write_watchlist` function (writes `-W <dir>` lines for watchexec @argfile)
9. Add main `watch` function with:
   - Process tracking via `current_process` ref
   - Temp file tracking via `current_watchlist` ref
   - SIGINT handler for clean shutdown
   - `Unix.open_process` for stdin/stdout control
   - Broad exception handling for build errors
10. Update `bin/mach.ml` to add `--watch` flag to build command
11. Add basic test in `test/test_watch.t`
12. Test manually with real files

## Open Questions

1. Should we also support `--watch` for `mach run`? It would need to restart the running process on changes. This could be a follow-up feature. No!

2. ~~Should we print a summary of watched files/directories on startup?~~ **Resolved**: Yes, we now print the list of watched directories on startup and after each restart.

3. Should there be a `--watch-only` mode that doesn't do an initial build? No!
