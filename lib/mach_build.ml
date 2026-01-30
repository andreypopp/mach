(** A simple build system implementation in OCaml. *)

open! Sexplib0.Sexp_conv
open! StdLabels
open! Mach_std

module Build_file_format = struct
  type stanza =
    | Rule of {
        targets: string array; (** absolute paths of targets rule produces *)
        deps: string array; (** absolute paths of dependencies rule requires *)
        commands: string array; (** a list of shell commands to execute to build the targets *)
      }
    | Rule_dyndep of {
        target: string; (** absolute path of a target containing dyndep *)
        deps: string array; (** absolute paths of dependencies rule requires *)
        commands: string array; (** a list of shell commands to execute to build the target *)
      }
  [@@deriving sexp]

  type t = stanza list

  let of_string s = Parsexp.Many.parse_string_exn s |> List.map ~f:stanza_of_sexp
  let of_file file_path = of_string (In_channel.(with_open_text file_path input_all))

  let to_string t =
    List.map t ~f:sexp_of_stanza
    |> List.map ~f:Sexplib0.Sexp.to_string_hum
    |> String.concat ~sep:"\n"

  let to_file file_path t =
    let s = to_string t in
    atomic_write_file file_path (fun oc -> output_string oc s)
end

module Dyndep_file_format = struct
  type dyndep = {
    target: string; (** absolute path of target that lists additional dependencies *)
    deps: string array; (** absolute paths of additional dependencies *)
  } [@@deriving sexp]

  type t = dyndep list

  let of_string s : t = Parsexp.Many.parse_string_exn s |> List.map ~f:dyndep_of_sexp
  let of_file file_path : t = of_string (In_channel.(with_open_text file_path input_all))

  let to_string t : string =
    List.map t ~f:sexp_of_dyndep
    |> List.map ~f:Sexplib0.Sexp.to_string_hum
    |> String.concat ~sep:"\n"

  let to_file file_path t : unit =
    let s = to_string t in
    atomic_write_file file_path (fun oc -> output_string oc s)
end

module T = Hashtbl.Make(String)

type t = { rules : rule T.t; }

and rule = {
  deps : string array;
  mutable dyndeps : string array;  (* extra deps discovered via dyndeps at build time *)
  commands : string array;
  target : target;
  mutable deps_pending: int;
  mutable built: bool;
}

and target = Targets of string array | Target_dyndep of string

let rule_targets (rule : rule) =
  match rule.target with
  | Targets targets -> targets
  | Target_dyndep target -> [|target|]

let needs_rebuild (rule : rule) =
  let targets = rule_targets rule in
  (* Get oldest target mtime, or None if any target missing *)
  let target_mtime =
    Array.fold_left ~init:(Some Float.max_float) ~f:(fun acc target_path ->
      match acc, file_stat target_path with
      | None, _ -> None
      | _, None -> None
      | Some oldest, Some stat -> Some (Float.min oldest stat.mtime)
    ) targets
  in
  match target_mtime with
  | None -> true  (* target doesn't exist *)
  | Some target_mtime ->
    (* Check if any dep (static or dynamic) is newer *)
    let dep_is_newer dep_path =
      match file_stat dep_path with
      | None -> true  (* dep missing, rebuild to get error *)
      | Some stat -> stat.mtime > target_mtime
    in
    Array.exists ~f:dep_is_newer rule.deps || Array.exists ~f:dep_is_newer rule.dyndeps

let create () : t =
  { rules = T.create 256; }

let configure t (rules : Build_file_format.stanza list) : unit =
  List.iter rules ~f:(fun (rule : Build_file_format.stanza) ->
    let target, deps, commands =
      match rule with
      | Build_file_format.Rule { targets; deps; commands } ->
        Targets targets, deps, commands
      | Build_file_format.Rule_dyndep { target; deps; commands } ->
        Target_dyndep target, deps, commands
    in
    let rule = { target; deps; dyndeps = [||]; commands; deps_pending = Array.length deps; built = false } in
    Array.iter (rule_targets rule) ~f:(fun target ->
      T.replace t.rules target rule))

let build_rule (rule : rule) =
  let targets = rule_targets rule in
  if rule.built then failwithf "target already built: %s"
    (String.concat ~sep:", " (Array.to_list targets));
  assert (rule.deps_pending = 0);
  Array.iter targets ~f:(fun t ->
    Mach_log.log_very_very_verbose "mach: building %s" t);
  let dev_null = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close dev_null) @@ fun () ->
  Array.iter rule.commands ~f:begin fun cmd ->
    let pipe_read, pipe_write = Unix.pipe () in
    Fun.protect ~finally:(fun () -> Unix.close pipe_read) @@ fun () ->
    let pid = Unix.create_process "/bin/sh" [|"/bin/sh"; "-c"; cmd|]
      dev_null pipe_write pipe_write in
    Unix.close pipe_write;
    let buf = Bytes.create 4096 in
    let rec read_loop () =
      let n = Unix.read pipe_read buf 0 4096 in
      if n > 0 then begin
        ignore (Unix.write Unix.stderr buf 0 n);
        read_loop ()
      end
    in
    read_loop ();
    let _, status = Unix.waitpid [] pid in
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Mach_error.user_errorf "build error"
  end;
  rule.built <- true

type rev_deps = target list ref T.t

let add_rev_dep rev_deps target_path target =
  let targets =
    match T.find_opt rev_deps target_path with
    | Some targets -> targets
    | None ->
      let targets = ref [] in
      T.replace rev_deps target_path targets;
      targets
  in
  targets := target :: !targets

let iter_rev_deps rev_deps rule ~f =
  Array.iter (rule_targets rule) ~f:(fun target_path ->
  match T.find_opt rev_deps target_path with
  | Some targets -> List.iter !targets ~f
  | None -> ())

type build_queue = rule Queue.t

module Rules = struct
  type t = Build_file_format.stanza list ref

  let create () : t = ref []
  let add (t : t) stanza = t := stanza :: !t
  let to_list (t : t) = List.rev !t

  let rule t ~target ~deps commands =
    add t (Build_file_format.Rule {
      targets = [|target|];
      deps = Array.of_list deps;
      commands = Array.of_list commands;
    })

  let rulef t ~target ~deps fmt =
    Printf.ksprintf (fun cmd -> rule t ~target ~deps [cmd]) fmt

  let rule_dyndep t ~target ~deps commands =
    add t (Build_file_format.Rule_dyndep {
      target;
      deps = Array.of_list deps;
      commands = Array.of_list commands;
    })
end

type in_flight_build = {
  rule: rule;
  pid: int;
  pipe_read: Unix.file_descr;
  output_buffer: Buffer.t;
  cmd_index: int;  (* which command in commands array is running *)
}

let start_command (rule : rule) (cmd_index : int) : in_flight_build option =
  if cmd_index >= Array.length rule.commands then
    None  (* All commands complete *)
  else begin
    let cmd = rule.commands.(cmd_index) in
    let dev_null = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
    let pipe_read, pipe_write = Unix.pipe () in
    let pid = Unix.create_process "/bin/sh" [|"/bin/sh"; "-c"; cmd|]
      dev_null pipe_write pipe_write in
    Unix.close dev_null;
    Unix.close pipe_write;
    Unix.set_nonblock pipe_read;
    Some {
      rule;
      pid;
      pipe_read;
      output_buffer = Buffer.create 4096;
      cmd_index;
    }
  end

let start_build (rule : rule) : in_flight_build option =
  assert (not rule.built);
  assert (rule.deps_pending = 0);
  Array.iter (rule_targets rule) ~f:(Mach_log.log_very_very_verbose "mach: building %s");
  start_command rule 0

let drain_output (build : in_flight_build) =
  let buf = Bytes.create 4096 in
  let rec loop () =
    try
      let n = Unix.read build.pipe_read buf 0 4096 in
      if n > 0 then begin
        Buffer.add_subbytes build.output_buffer buf 0 n;
        loop ()
      end
    with
    | Unix.Unix_error (Unix.EAGAIN, _, _)
    | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) -> ()
  in
  loop ()

let flush_output (build : in_flight_build) =
  let output = Buffer.contents build.output_buffer in
  if String.length output > 0 then
    output_string stderr output;
  Buffer.clear build.output_buffer

let poll_build (build : in_flight_build) : [`Running | `Exited of Unix.process_status] =
  drain_output build;
  match Unix.waitpid [Unix.WNOHANG] build.pid with
  | 0, _ -> `Running
  | _, status ->
    drain_output build;
    flush_output build;
    Unix.close build.pipe_read;
    `Exited status

let handle_command_complete (build : in_flight_build) (status : Unix.process_status)
    : [`Done | `Continue of in_flight_build | `Error of string] =
  match status with
  | Unix.WEXITED 0 ->
    begin match start_command build.rule (build.cmd_index + 1) with
    | None -> build.rule.built <- true; `Done
    | Some next_build -> `Continue next_build
    end
  | Unix.WEXITED code       -> `Error (Printf.sprintf "build error (exit %d)" code)
  | Unix.WSIGNALED sig_num  -> `Error (Printf.sprintf "build error (signal %d)" sig_num)
  | Unix.WSTOPPED _         -> `Error "build error (stopped)"


let build t ~target_path ~parallelism =
  let queue : build_queue = Queue.create () in (* targets ready to build *)
  let rev_deps : rule list ref T.t = T.create 256 in (* next targets to schedule after build of a target *)
  let visiting : unit T.t = T.create 256 in

  let in_flight : in_flight_build list ref = ref [] in
  let error_occurred : string option ref = ref None in

  let rec schedule ?rev_dep target_path =
    if T.mem visiting target_path then Mach_error.user_errorf "dependency cycle detected: %s" target_path;
    T.add visiting target_path ();
    begin match T.find_opt t.rules target_path with
    | None -> (* not a target we know about, a source file perhaps, just notify rev_deps *)
      Option.iter (fun rule ->
        rule.deps_pending <- rule.deps_pending - 1;
        if rule.deps_pending = 0 then Queue.add rule queue) rev_dep
    | Some rule ->
      if rule.built then begin
        Option.iter (fun rev_dep_rule ->
          rev_dep_rule.deps_pending <- rev_dep_rule.deps_pending - 1;
          if rev_dep_rule.deps_pending = 0 then Queue.add rev_dep_rule queue
        ) rev_dep
      end else if T.mem rev_deps target_path then
        Option.iter (add_rev_dep rev_deps target_path) rev_dep
      else begin
        Option.iter (add_rev_dep rev_deps target_path) rev_dep;
        if rule.deps_pending = 0
        then Queue.add rule queue
        else Array.iter rule.deps ~f:(schedule ~rev_dep:rule)
      end
    end;
    T.remove visiting target_path
  in

  let process_completed (rule : rule) =
    begin match rule.target with
    | Targets _ -> ()
    | Target_dyndep target ->
      List.iter (Dyndep_file_format.of_file target) ~f:(fun (dyndep : Dyndep_file_format.dyndep) ->
        match T.find_opt t.rules dyndep.target with
        | None ->
          error_occurred := Some (Printf.sprintf "dyndep references unknown target: %s" dyndep.target)
        | Some dep_rule ->
          if dep_rule.deps_pending = 0 then
            error_occurred := Some (Printf.sprintf
              "dyndep references target that is already scheduled/built: %s" dyndep.target)
          else begin
            dep_rule.dyndeps <- Array.append dep_rule.dyndeps dyndep.deps;
            dep_rule.deps_pending <- dep_rule.deps_pending + Array.length dyndep.deps;
            Array.iter dyndep.deps ~f:(schedule ~rev_dep:dep_rule)
          end)
    end;
    iter_rev_deps rev_deps rule ~f:(fun rule ->
      rule.deps_pending <- rule.deps_pending - 1;
      if rule.deps_pending = 0 then Queue.add rule queue)
  in

  let start_pending_builds () =
    while List.length !in_flight < parallelism
          && not (Queue.is_empty queue)
          && Option.is_none !error_occurred do
      let rule = Queue.take queue in
      if needs_rebuild rule then
        match start_build rule with
        | Some build -> in_flight := build :: !in_flight
        | None -> rule.built <- true; process_completed rule
      else begin
        rule.built <- true;  (* Up-to-date, mark as built *)
        process_completed rule
      end
    done
  in

  let rec process_in_flight in_flight = function
    | [] -> in_flight
    | build :: rest ->
    match poll_build build with
    | `Running -> process_in_flight (build::in_flight) rest
    | `Exited status ->
      match handle_command_complete build status with
      | `Done -> process_completed build.rule; process_in_flight in_flight rest
      | `Continue next_build -> process_in_flight (next_build::in_flight) rest
      | `Error msg -> error_occurred := Some msg; process_in_flight in_flight rest
  in

  let rec build_loop () =
    start_pending_builds ();
    Option.iter (Mach_error.user_errorf "%s") !error_occurred;
    if !in_flight = [] then ()
    else begin
      let read_fds = List.map ~f:(fun (b : in_flight_build) -> b.pipe_read) !in_flight in
      let _, _, _ = Unix.select read_fds [] [] 0.05 in  (* 50ms timeout *)
      in_flight := process_in_flight [] !in_flight;
      build_loop ()
    end
  in

  schedule target_path;
  build_loop ()
