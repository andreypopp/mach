(* mach_lib - Shared code for mach and mach-lsp *)

(* --- User error handling --- *)

(** Used only internally, do not expose outside this module, all functions
    which raise such exception must convert to `('a, error) result` returning
    functions before exposing them to public API. *)
exception Mach_user_error of string

let user_error msg = raise (Mach_user_error msg)

type error = [`User_error of string]

let catch_user_error f =
  try Ok (f ())
  with Mach_user_error msg -> Error (`User_error msg)

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

let module_name_of_path path = Filename.(basename path |> remove_extension)

let failwithf fmt = ksprintf failwith fmt
let rm_rf path =
  let cmd = sprintf "rm -rf %s" (Filename.quote path) in
  if Sys.command cmd <> 0 then failwithf "Command failed: %s" cmd

let mli_path_of_ml_if_exists path =
  let base = Filename.remove_extension path in
  let mli = base ^ ".mli" in
  if Sys.file_exists mli then Some mli else None

let resolve_require ~source_path ~line path =
  let path =
    if Filename.is_relative path
    then Filename.(dirname source_path / path)
    else path
  in
  try Unix.realpath path
  with Unix.Unix_error (err, _, _) ->
    user_error (sprintf "%s:%d: %s: %s" source_path line path (Unix.error_message err))

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let write_file path content = Out_channel.with_open_text path (fun oc -> output_string oc content)

let mach_executable_path =
  lazy (
    match Sys.backend_type with
    | Sys.Native -> Unix.realpath Sys.executable_name
    | Sys.Bytecode ->
      let script =
        let path = Sys.argv.(0) in
        if Filename.is_relative path then Filename.(Sys.getcwd () / path) else path
      in
      Printf.sprintf "%s -I +unix unix.cma %s"
        (Filename.quote Sys.executable_name) (Filename.quote (Unix.realpath script))
    | Sys.Other _ -> failwith "mach must be run as a native/bytecode executable"
  )
let mach_executable_path () = Lazy.force mach_executable_path

(* --- Parsing and preprocessing --- *)

let is_empty_line line = String.for_all (function ' ' | '\t' -> true | _ -> false) line
let is_shebang line = String.length line >= 2 && line.[0] = '#' && line.[1] = '!'
let is_directive line = String.length line >= 1 && line.[0] = '#'

let is_require_path s =
  String.length s > 0 && (
    String.starts_with ~prefix:"/" s ||
    String.starts_with ~prefix:"./" s ||
    String.starts_with ~prefix:"../" s)

let extract_requires_exn source_path : requires:string list * libs:string list =
  let rec parse line_num (~requires, ~libs) ic =
    match In_channel.input_line ic with
    | Some line when is_shebang line -> parse (line_num + 1) (~requires, ~libs) ic
    | Some line when is_directive line ->
      let req =
        try Scanf.sscanf line "#require %S%_s" Fun.id
        with Scanf.Scan_failure _ | End_of_file -> user_error (sprintf "%s:%d: invalid #require directive" source_path line_num)
      in
      if is_require_path req then
        let requires = resolve_require ~source_path ~line:line_num req::requires in
        parse (line_num + 1) (~requires, ~libs) ic
      else
        parse (line_num + 1) (~requires, ~libs:(req :: libs)) ic
    | Some line when is_empty_line line -> parse (line_num + 1) (~requires, ~libs) ic
    | None | Some _ -> ~requires:(List.rev requires), ~libs:(List.rev libs)
  in
  In_channel.with_open_text source_path (parse 1 (~requires:[], ~libs:[]))

let extract_requires source_path =
  catch_user_error @@ fun () -> extract_requires_exn source_path

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

(* --- Build backend types (re-exported from Mach_config) --- *)

type build_backend = Mach_config.build_backend = Make | Ninja

let string_of_build_backend = Mach_config.string_of_build_backend
let build_backend_of_string = Mach_config.build_backend_of_string

(* --- State cache --- *)

module Mach_state : sig
  type file_stat = { mtime: int; size: int }
  type entry = { ml_path: string; mli_path: string option; ml_stat: file_stat; mli_stat: file_stat option; requires: string list; libs: string list }
  type metadata = { build_backend: build_backend; mach_path: string }
  type t = { metadata: metadata; root: entry; entries: entry list }  (* topo-sorted: dependencies first, root last *)

  val read : string -> t option
  val write : string -> t -> unit
  val needs_reconfigure : build_backend:build_backend -> mach_path:string -> t -> bool
  val collect_exn : build_backend:build_backend -> mach_path:string -> string -> t
  val collect : build_backend:build_backend -> mach_path:string -> string -> (t, error) result

  val exe_path : Mach_config.t -> t -> string (** executable path *)

  val source_dirs : t -> string list (** list of source dirs *)

  val all_libs : t -> string list (** all unique libs from all entries *)
end = struct
  type file_stat = { mtime: int; size: int }
  let equal_file_state x y = x.mtime = y.mtime && x.size = y.size

  type entry = { ml_path: string; mli_path: string option; ml_stat: file_stat; mli_stat: file_stat option; requires: string list; libs: string list }
  type metadata = { build_backend: build_backend; mach_path: string }
  type t = { metadata: metadata; root: entry; entries: entry list }  (* topo-sorted: dependencies first, root last *)

  let exe_path config t = Filename.(Mach_config.build_dir_of config t.root.ml_path / "a.out")

  let source_dirs state =
    let seen = Hashtbl.create 16 in
    let add_dir path = Hashtbl.replace seen (Filename.dirname path) () in
    List.iter (fun entry-> add_dir entry.ml_path) state.entries;
    Hashtbl.fold (fun dir () acc -> dir :: acc) seen []
    |> List.sort String.compare

  let all_libs state =
    let seen = Hashtbl.create 16 in
    let libs = ref [] in
    List.iter (fun entry ->
      List.iter (fun lib ->
        if not (Hashtbl.mem seen lib) then begin
          Hashtbl.add seen lib ();
          libs := lib :: !libs
        end
      ) entry.libs
    ) state.entries;
    List.rev !libs

  let file_stat path =
    let st = Unix.stat path in
    { mtime = Int.of_float st.Unix.st_mtime; size = st.Unix.st_size }

  let read path =
    if not (Sys.file_exists path) then None
    else try
      let lines = In_channel.with_open_text path In_channel.input_lines in
      (* Parse metadata header *)
      let metadata, entry_lines = match lines with
        | bb_line :: mp_line :: "" :: rest ->
          let build_backend = Scanf.sscanf bb_line "build_backend %s" build_backend_of_string in
          let mach_path = Scanf.sscanf mp_line "mach_path %s@\n" Fun.id in
          Some { build_backend; mach_path }, rest
        | _ -> None, []  (* Missing metadata = needs reconfigure *)
      in
      match metadata with
      | None -> None
      | Some metadata ->
        let mli_path_of ml_path =
          let base = Filename.remove_extension ml_path in
          Some (base ^ ".mli")
        in
        let finalize cur = {cur with requires = List.rev cur.requires; libs = List.rev cur.libs} in
        let rec loop acc cur = function
          | [] -> (match cur with Some cur -> finalize cur :: acc | None -> acc)
          | line :: rest when String.length line > 6 && String.sub line 0 6 = "  mli " ->
            let e = Option.get cur in
            let m, s = Scanf.sscanf line "  mli %i %d" (fun m s -> m, s) in
            loop acc (Some { e with mli_path = mli_path_of e.ml_path; mli_stat = Some { mtime = m; size = s } }) rest
          | line :: rest when String.length line > 6 && String.sub line 0 6 = "  lib " ->
            let e = Option.get cur in
            let lib = Scanf.sscanf line "  lib %s" Fun.id in
            loop acc (Some { e with libs = lib :: e.libs }) rest
          | line :: rest when String.length line > 2 && line.[0] = ' ' ->
            let e = Option.get cur in
            loop acc (Some { e with requires = Scanf.sscanf line "  requires %s" Fun.id :: e.requires }) rest
          | line :: rest ->
            let acc = match cur with Some cur -> finalize cur :: acc | None -> acc in
            let p, m, s = Scanf.sscanf line "%s %i %d" (fun p m s -> p, m, s) in
            loop acc (Some { ml_path = p; mli_path = None; ml_stat = { mtime = m; size = s }; mli_stat = None; requires = []; libs = [] }) rest
        in
        match loop [] None entry_lines with
        | [] -> None
        | root::_ as entries -> Some { metadata; root; entries = List.rev entries }
    with _ -> None

  let write path state =
    Out_channel.with_open_text path (fun oc ->
      (* Write metadata header *)
      Buffer.output_line oc (sprintf "build_backend %s" (string_of_build_backend state.metadata.build_backend));
      Buffer.output_line oc (sprintf "mach_path %s" state.metadata.mach_path);
      Buffer.output_line oc "";
      (* Write entries *)
      List.iter (fun e ->
        Buffer.output_line oc (sprintf "%s %i %d" e.ml_path e.ml_stat.mtime e.ml_stat.size);
        Option.iter (fun st -> Buffer.output_line oc (sprintf "  mli %i %d" st.mtime st.size)) e.mli_stat;
        List.iter (fun r -> Buffer.output_line oc (sprintf "  requires %s" r)) e.requires;
        List.iter (fun l -> Buffer.output_line oc (sprintf "  lib %s" l)) e.libs
      ) state.entries)

  let needs_reconfigure ~build_backend ~mach_path state =
    if state.metadata.build_backend <> build_backend then
      (log_very_verbose "mach:state: build backend changed, need reconfigure"; true)
    else if state.metadata.mach_path <> mach_path then
      (log_very_verbose "mach:state: mach path changed, need reconfigure"; true)
    else
      List.exists (fun entry ->
        if not (Sys.file_exists entry.ml_path)
        then (log_very_verbose "mach:state: file removed, need reconfigure"; true)
        else
          if mli_path_of_ml_if_exists entry.ml_path <> entry.mli_path
          then (log_very_verbose "mach:state: .mli added/removed, need reconfigure"; true)
          else
            if not (equal_file_state (file_stat entry.ml_path) entry.ml_stat)
            then
              let ~requires, ~libs = extract_requires_exn entry.ml_path in
              if requires <> entry.requires || libs <> entry.libs
              then (log_very_verbose "mach:state: requires/libs changed, need reconfigure"; true)
              else false
            else false
      ) state.entries

  let collect_exn ~build_backend ~mach_path entry_path =
    let entry_path = Unix.realpath entry_path in
    let metadata = { build_backend; mach_path } in
    let visited = Hashtbl.create 16 in
    let entries = ref [] in
    let rec dfs ml_path =
      if Hashtbl.mem visited ml_path then ()
      else begin
        Hashtbl.add visited ml_path ();
        let ~requires, ~libs = extract_requires_exn ml_path in
        List.iter dfs requires;
        let mli_path = mli_path_of_ml_if_exists ml_path in
        let mli_stat = Option.map file_stat mli_path in
        entries := { ml_path; mli_path; ml_stat = file_stat ml_path; mli_stat; requires; libs } :: !entries
      end
    in
    dfs entry_path;
    match !entries with
    | [] -> failwith "Internal error: no entries collected"
    | root::_ as entries -> { metadata; root; entries = List.rev entries }

  let collect ~build_backend ~mach_path entry_path = catch_user_error @@ fun () -> collect_exn ~build_backend ~mach_path entry_path
end

(* --- PP (for merlin and build) --- *)

let pp source_path =
  In_channel.with_open_text source_path (fun ic ->
    preprocess_source ~source_path stdout ic);
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
  let cmd = state.Mach_state.metadata.mach_path in
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
  let build_backend = config.Mach_config.build_backend in
  let build_dir_of = Mach_config.build_dir_of config in
  let source_path = Unix.realpath source_path in
  let build_dir = build_dir_of source_path in
  let state_path = Filename.(build_dir / "Mach.state") in
  let mach_path = mach_executable_path () in
  let state, needs_reconfigure =
    match Mach_state.read state_path with
    | None ->
      log_very_verbose "mach:configure: no previous state found, creating one...";
      Mach_state.collect_exn ~build_backend ~mach_path source_path, true
    | Some state when Mach_state.needs_reconfigure ~build_backend ~mach_path state ->
      log_very_verbose "mach:configure: need reconfigure";
      Mach_state.collect_exn ~build_backend ~mach_path source_path, true
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
  catch_user_error @@ fun () -> configure_exn config source_path

(* --- Build --- *)

let build_exn config script_path =
  let build_dir_of = Mach_config.build_dir_of config in
  let ~state, ~reconfigured = configure_exn config script_path in
  log_verbose "mach: building...";
  let cmd = match config.Mach_config.build_backend with
    | Make -> if !verbose = Very_very_verbose then "make all" else "make -s all"
    | Ninja -> if !verbose = Very_very_verbose then "ninja -v" else "ninja --quiet"
  in
  let cmd = sprintf "%s -C %s" cmd (Filename.quote (build_dir_of state.root.ml_path)) in
  if !verbose = Very_very_verbose then eprintf "+ %s\n%!" cmd;
  if Sys.command cmd <> 0 then user_error "build failed";
  ~state, ~reconfigured

let build config script_path =
  catch_user_error @@ fun () -> build_exn config script_path

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
    user_error "watchexec not found. Install it: https://github.com/watchexec/watchexec";
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
  catch_user_error @@ fun () -> watch_exn config script_path
