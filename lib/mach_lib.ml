(* mach_lib - Shared code for mach and mach-lsp *)

(* --- Utilities --- *)

open Printf

type verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let verbose = ref Quiet

let log_at level fmt = ksprintf (fun msg -> if !verbose >= level then eprintf "%s\n%!" msg) fmt
let log_verbose fmt = log_at Verbose fmt
let log_very_verbose fmt = log_at Very_verbose fmt

module Filename = struct
  include Filename
  let (/) = concat
end

module Buffer = struct
  include Buffer
  let output_line oc line = output_string oc line; output_char oc '\n'
end

let config_dir =
  lazy (
    match Sys.getenv_opt "MACH_HOME" with
    | Some dir -> dir
    | None -> Filename.(Sys.getenv "HOME" / ".cache" / "mach"))
let config_dir () = Lazy.force config_dir

let build_dir_of script_path =
  let normalized = String.split_on_char '/' script_path |> String.concat "__" in
  Filename.(config_dir () / "build" / normalized)

let module_name_of_path path = Filename.(basename path |> remove_extension)

let failwithf fmt = ksprintf failwith fmt
let commandf fmt = ksprintf (fun cmd -> if Sys.command cmd <> 0 then failwithf "Command failed: %s" cmd) fmt
let rm_rf path = commandf "rm -rf %s" (Filename.quote path)

let mli_path_of_ml_if_exists path =
  let base = Filename.remove_extension path in
  let mli = base ^ ".mli" in
  if Sys.file_exists mli then Some mli else None

let resolve_path ~relative_to path =
  if Filename.is_relative path
  then Unix.realpath Filename.(dirname relative_to / path)
  else Unix.realpath path

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let write_file path content = Out_channel.with_open_text path (fun oc -> output_string oc content)

(* --- Parsing and preprocessing --- *)

let is_empty_line line = String.for_all (function ' ' | '\t' -> true | _ -> false) line
let is_shebang line = String.length line >= 2 && line.[0] = '#' && line.[1] = '!'
let is_directive line = String.length line >= 1 && line.[0] = '#'

let extract_requires source_path =
  let rec parse acc ic =
    match In_channel.input_line ic with
    | None -> List.rev acc
    | Some line when is_shebang line -> parse acc ic
    | Some line when is_directive line -> parse (Scanf.sscanf line "#require %S%_s" Fun.id :: acc) ic
    | Some line when is_empty_line line -> parse acc ic
    | Some _ -> List.rev acc
  in
  In_channel.with_open_text source_path (parse [])
  |> List.map (resolve_path ~relative_to:source_path)

let preprocess_source ~source_path oc ic =
  fprintf oc "# 1 %S\n" source_path;
  let rec loop in_header =
    match In_channel.input_line ic with
    | None -> ()
    | Some line when is_empty_line line -> Buffer.output_line oc line; loop in_header
    | Some line when in_header && is_directive line -> Buffer.output_line oc ""; loop true
    | Some line -> Buffer.output_line oc line; loop false
  in
  loop true

(* --- State cache --- *)

module Mach_state : sig
  type file_stat = { mtime: int; size: int }
  type entry = { ml_path: string; mli_path: string option; ml_stat: file_stat; mli_stat: file_stat option; requires: string list }
  type t = { root: entry; entries: entry list }  (* topo-sorted: dependencies first, root last *)

  val read : string -> t option
  val write : string -> t -> unit
  val needs_reconfigure : t -> bool
  val collect : string -> t

  val exe_path : t -> string (** executable path *)

  val source_dirs : t -> string list (** list of source dirs *)
end = struct
  type file_stat = { mtime: int; size: int }
  let equal_file_state x y = x.mtime = y.mtime && x.size = y.size

  type entry = { ml_path: string; mli_path: string option; ml_stat: file_stat; mli_stat: file_stat option; requires: string list }
  type t = { root: entry; entries: entry list }  (* topo-sorted: dependencies first, root last *)

  let exe_path t = Filename.(build_dir_of t.root.ml_path / "a.out")

  let source_dirs state =
    let seen = Hashtbl.create 16 in
    let add_dir path = Hashtbl.replace seen (Filename.dirname path) () in
    List.iter (fun entry-> add_dir entry.ml_path) state.entries;
    Hashtbl.fold (fun dir () acc -> dir :: acc) seen []
    |> List.sort String.compare

  let file_stat path =
    let st = Unix.stat path in
    { mtime = Int.of_float st.Unix.st_mtime; size = st.Unix.st_size }

  let read path =
    if not (Sys.file_exists path) then None
    else try
      let lines = In_channel.with_open_text path In_channel.input_lines in
      let mli_path_of ml_path =
        let base = Filename.remove_extension ml_path in
        Some (base ^ ".mli")
      in
      let finalize cur = {cur with requires = List.rev cur.requires} in
      let rec loop acc cur = function
        | [] -> (match cur with Some cur -> finalize cur :: acc | None -> acc)
        | line :: rest when String.length line > 6 && String.sub line 0 6 = "  mli " ->
          let e = Option.get cur in
          let m, s = Scanf.sscanf line "  mli %i %d" (fun m s -> m, s) in
          loop acc (Some { e with mli_path = mli_path_of e.ml_path; mli_stat = Some { mtime = m; size = s } }) rest
        | line :: rest when String.length line > 2 && line.[0] = ' ' ->
          let e = Option.get cur in
          loop acc (Some { e with requires = Scanf.sscanf line "  requires %s" Fun.id :: e.requires }) rest
        | line :: rest ->
          let acc = match cur with Some cur -> finalize cur :: acc | None -> acc in
          let p, m, s = Scanf.sscanf line "%s %i %d" (fun p m s -> p, m, s) in
          loop acc (Some { ml_path = p; mli_path = None; ml_stat = { mtime = m; size = s }; mli_stat = None; requires = [] }) rest
      in
      match loop [] None lines with
      | [] -> None
      | root::_ as entries -> Some { root; entries = List.rev entries }
    with _ -> None

  let write path state =
    Out_channel.with_open_text path (fun oc ->
      List.iter (fun e ->
        Buffer.output_line oc (sprintf "%s %i %d" e.ml_path e.ml_stat.mtime e.ml_stat.size);
        Option.iter (fun st -> Buffer.output_line oc (sprintf "  mli %i %d" st.mtime st.size)) e.mli_stat;
        List.iter (fun r -> Buffer.output_line oc (sprintf "  requires %s" r)) e.requires
      ) state.entries)

  let needs_reconfigure state =
    List.exists (fun entry ->
      if not (Sys.file_exists entry.ml_path)
      then (log_very_verbose "mach:state: file removed, need reconfigure"; true)
      else
        if mli_path_of_ml_if_exists entry.ml_path <> entry.mli_path
        then (log_very_verbose "mach:state: .mli added/removed, need reconfigure"; true)
        else
          if not (equal_file_state (file_stat entry.ml_path) entry.ml_stat)
          then
            let requires = extract_requires entry.ml_path in
            if requires <> entry.requires
            then (log_very_verbose "mach:state: requires changed, need reconfigure"; true)
            else false
          else false
    ) state.entries

  let collect entry_path =
    let entry_path = Unix.realpath entry_path in
    let visited = Hashtbl.create 16 in
    let entries = ref [] in
    let rec dfs ml_path =
      if Hashtbl.mem visited ml_path then ()
      else begin
        Hashtbl.add visited ml_path ();
        let requires = extract_requires ml_path in
        List.iter dfs requires;
        let mli_path = mli_path_of_ml_if_exists ml_path in
        let mli_stat = Option.map file_stat mli_path in
        entries := { ml_path; mli_path; ml_stat = file_stat ml_path; mli_stat; requires } :: !entries
      end
    in
    dfs entry_path;
    match !entries with
    | [] -> failwith "Internal error: no entries collected"
    | root::_ as entries -> { root; entries = List.rev entries }
end

(* --- Build backend types --- *)

type build_backend = Make | Ninja

(* --- Preprocess --- *)

let preprocess build_dir src_ml =
  let src_ml = Unix.realpath src_ml in
  let module_name = module_name_of_path src_ml in
  let build_ml = Filename.(build_dir / module_name ^ ".ml") in
  Out_channel.with_open_text build_ml (fun oc ->
    In_channel.with_open_text src_ml (fun ic ->
      preprocess_source ~source_path:src_ml oc ic));
  Option.iter (fun src_mli ->
    let build_mli = Filename.(build_dir / module_name ^ ".mli") in
    Out_channel.with_open_text build_mli (fun oc ->
      fprintf oc "# 1 %S\n" src_mli;
      let content = In_channel.with_open_text src_mli In_channel.input_all in
      output_string oc content)
  ) (mli_path_of_ml_if_exists src_ml)

(* --- PP (for merlin) --- *)

let pp source_path =
  In_channel.with_open_text source_path (fun ic ->
    preprocess_source ~source_path stdout ic);
  flush stdout

(* --- Configure --- *)

type ocaml_module = {
  ml_path: string;
  mli_path: string option;
  cmo: string;
  cmi: string;
  cmt: string;
  module_name: string;
  build_dir: string;
  resolved_requires: string list;  (* absolute paths *)
}

let configure_backend ~build_backend state =
  let (module B : S.BUILD), module_file, root_file =
    match build_backend with
    | Make -> (module Makefile), "mach.mk", "Makefile"
    | Ninja -> (module Ninja), "mach.ninja", "build.ninja"
  in
  let configure_ocaml_module b (m : ocaml_module) =
    let ml = Filename.(m.build_dir / m.module_name ^ ".ml") in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    let preprocess_deps = m.ml_path :: Option.to_list m.mli_path in
    let cmd =
      match Sys.backend_type with
      | Sys.Native -> Sys.executable_name
      | Sys.Bytecode ->
        let script = resolve_path ~relative_to:Filename.(Sys.getcwd () / "x") Sys.argv.(0) in
        Printf.sprintf "%s -I +unix unix.cma %s"
          (Filename.quote Sys.executable_name) (Filename.quote script)
      | Sys.Other _ -> failwith "mach must be run as a native/bytecode executable"
    in
    B.rulef b ~target:ml ~deps:preprocess_deps "%s preprocess %s -o %s" cmd m.ml_path m.build_dir;
    if Option.is_some m.mli_path then B.rule b ~target:mli ~deps:[ml] [];
    let args = Filename.(m.build_dir / "includes.args") in
    let recipe =
      match m.resolved_requires with
      | [] -> [sprintf "touch %s" args]
      | requires -> List.map (fun p -> sprintf "echo '-I=%s' >> %s" (build_dir_of p) args) requires
    in
    B.rule b ~target:args ~deps:[ml] (sprintf "rm -f %s" args :: recipe)
  in
  let compile_ocaml_module b (m : ocaml_module) =
    let ml = Filename.(m.build_dir / m.module_name ^ ".ml") in
    let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
    let args = Filename.(m.build_dir / "includes.args") in
    let cmi_deps = List.map (fun p -> Filename.(build_dir_of p / module_name_of_path p ^ ".cmi")) m.resolved_requires in
    match m.mli_path with
    | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first, then .ml to .cmo/.cmt *)
      B.rulef b ~target:m.cmi ~deps:(mli :: args :: cmi_deps) "ocamlc -bin-annot -c -args %s -o %s %s" args m.cmi mli;
      B.rulef b ~target:m.cmo ~deps:[ml; m.cmi; args] "ocamlc -bin-annot -c -args %s -cmi-file %s -o %s %s" args m.cmi m.cmo ml;
      B.rule b ~target:m.cmt ~deps:[m.cmo] []
    | None -> (* Without .mli: current behavior *)
      B.rulef b ~target:m.cmo ~deps:(ml :: args :: cmi_deps) "ocamlc -bin-annot -c -args %s -o %s %s" args m.cmo ml;
      B.rule b ~target:m.cmi ~deps:[m.cmo] [];
      B.rule b ~target:m.cmt ~deps:[m.cmo] []
  in
  let link_ocaml_module b (all_objs : string list) ~exe_path =
    let args = Filename.(Filename.dirname exe_path / "all_objects.args") in
    let objs_str = String.concat " " all_objs in
    B.rulef b ~target:args ~deps:all_objs "printf '%%s\\n' %s > %s" objs_str args;
    B.rulef b ~target:exe_path ~deps:(args :: all_objs) "ocamlc -o %s -args %s" exe_path args
  in
  let modules = List.map (fun ({ml_path;mli_path;requires=resolved_requires;_} : Mach_state.entry) ->
    let module_name = module_name_of_path ml_path in
    let build_dir = build_dir_of ml_path in
    let cmo = Filename.(build_dir / module_name ^ ".cmo") in
    let cmi = Filename.(build_dir / module_name ^ ".cmi") in
    let cmt = Filename.(build_dir / module_name ^ ".cmt") in
    { ml_path; mli_path; module_name; build_dir; resolved_requires;cmo;cmi;cmt; }
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
  let exe_path = Mach_state.exe_path state in
  let all_objs = List.map (fun m -> m.cmo) modules in
  write_file Filename.(build_dir_of state.root.ml_path / root_file) (
    let b = B.create () in
    List.iter (fun entry ->
      B.include_ b Filename.(build_dir_of entry.Mach_state.ml_path / module_file)) state.entries;
    B.rule_phony b ~target:"all" ~deps:[exe_path];
    link_ocaml_module b all_objs ~exe_path;
    B.contents b
  )

let configure ?(build_backend=Make) source_path =
  let source_path = Unix.realpath source_path in
  let build_dir = build_dir_of source_path in
  let state_path = Filename.(build_dir / "Mach.state") in
  let state, needs_reconfigure =
    match Mach_state.read state_path with
    | None ->
      log_very_verbose "mach:configure: no previous state found, creating one...";
      Mach_state.collect source_path, true
    | Some state when Mach_state.needs_reconfigure state ->
      log_very_verbose "mach:configure: need reconfigure";
      Mach_state.collect source_path, true
    | Some state -> state, false
  in
  if needs_reconfigure then begin
    log_verbose "mach: configuring...";
    List.iter (fun entry -> rm_rf (build_dir_of entry.Mach_state.ml_path)) state.entries;
    mkdir_p build_dir;
    configure_backend ~build_backend state;
    Mach_state.write state_path state
  end;
  ~state, ~reconfigured:needs_reconfigure

(* --- Build --- *)

let build ?(build_backend=Make) script_path =
  let ~state, ~reconfigured = configure ~build_backend script_path in
  log_verbose "mach: building...";
  let cmd = match build_backend with
    | Make -> if !verbose = Very_very_verbose then "make all" else "make -s all"
    | Ninja -> if !verbose = Very_very_verbose then "ninja -v" else "ninja --quiet"
  in
  let cmd = sprintf "%s -C %s" cmd (Filename.quote (build_dir_of state.root.ml_path)) in
  if !verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
  commandf "%s" cmd;
  ~state, ~reconfigured

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

let watch ?(build_backend=Make) script_path =
  let exception Restart_watcher in
  let code = Sys.command "command -v watchexec > /dev/null 2>&1" in
  if code <> 0 then
    failwith "watchexec not found. Install it: https://github.com/watchexec/watchexec";
  let script_path = Unix.realpath script_path in

  log_verbose "mach: initial build...";
  let _ = build ~build_backend script_path in

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
          begin try
            let ~state:_, ~reconfigured = build ~build_backend script_path in
            log_verbose "mach: build succeeded";
            if reconfigured then begin
              log_verbose "mach:watch: reconfigured, restarting watcher...";
              raise Restart_watcher
            end
          with
          | Restart_watcher -> raise Restart_watcher
          | exn -> log_verbose "mach: build error: %s" (Printexc.to_string exn)
          end
        end
      done
    with
    | Restart_watcher -> cleanup ()
    | End_of_file -> cleanup (); keep_watching := false
    end
  done
