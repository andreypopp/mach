(** A simple build system implementation in OCaml. *)

open! Sexplib0.Sexp_conv
open! StdLabels
open! Mach_std

module Build_file_format = struct
  type stanza =
    | Rule of {
        targets: string array; [@sexp.array] (** absolute paths of targets rule produces *)
        deps: string array; [@sexp.array] (** absolute paths of dependencies rule requires *)
        commands: string array; [@sexp.array] (** a list of shell commands to execute to build the targets *)
      }
    | Rule_dyndep of {
        targets: string array; [@sexp.array] (** absolute path of a target containing dyndep *)
        deps: string array; [@sexp.array] (** absolute paths of dependencies rule requires *)
        commands: string array; [@sexp.array] (** a list of shell commands to execute to build the target *)
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
    deps: string array; [@sexp.array] (** absolute paths of additional dependencies *)
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
  targets : string array;
  mutable deps_pending: int;
  mutable visited: bool;   (* true once we've iterated this rule's deps *)
  mutable scheduled: bool; (* true once added to the build queue *)
  mutable built: bool;
  is_dyndep: bool;
}

let rule_targets (rule : rule) = rule.targets

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
    let targets, deps, commands, is_dyndep =
      match rule with
      | Build_file_format.Rule { targets; deps; commands } ->
        targets, deps, commands, false
      | Build_file_format.Rule_dyndep { targets; deps; commands } ->
        targets, deps, commands, true
    in
    let deps_pending = Array.length deps in
    let rule = { targets; deps; dyndeps = [||]; commands; deps_pending; visited = false; scheduled = false; built = false; is_dyndep } in
    Array.iter (rule_targets rule) ~f:(fun target ->
      T.replace t.rules target rule))

module Rev_deps = struct
  type t = rule list ref T.t

  let add (rev_deps : t) target_path target =
    let targets =
      match T.find_opt rev_deps target_path with
      | Some targets -> targets
      | None ->
        let targets = ref [] in
        T.replace rev_deps target_path targets;
        targets
    in
    targets := target :: !targets

  let iter (rev_deps : t) rule ~f =
    Array.iter (rule_targets rule) ~f:(fun target_path ->
    match T.find_opt rev_deps target_path with
    | Some targets -> List.iter !targets ~f
    | None -> ())
end

type build_queue = rule Queue.t

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
  let rev_deps : Rev_deps.t = T.create 256 in (* next targets to schedule after build of a target *)
  let visiting : unit T.t = T.create 256 in

  let in_flight : in_flight_build list ref = ref [] in
  let error_occurred : string option ref = ref None in

  let schedule_rule rule =
    rule.scheduled <- true;
    Queue.add rule queue
  in

  let dep_ready rule =
    if not rule.scheduled then (
      rule.deps_pending <- rule.deps_pending - 1;
      if rule.deps_pending = 0 then schedule_rule rule)
  in

  let rec schedule ?rev_dep target_path =
    if T.mem visiting target_path then Mach_error.user_errorf "dependency cycle detected: %s" target_path;
    T.add visiting target_path ();
    begin match T.find_opt t.rules target_path with
    | None -> (* not a target we know about, a source file perhaps, just notify rev_deps *)
      Option.iter dep_ready rev_dep
    | Some rule ->
      if rule.built then begin
        Option.iter dep_ready rev_dep
      end else if rule.visited then begin
        Array.iter rule.deps ~f:(fun dep ->
          if T.mem visiting dep then Mach_error.user_errorf "dependency cycle detected: %s" dep);
        Option.iter (Rev_deps.add rev_deps target_path) rev_dep
      end else begin
        rule.visited <- true;
        Option.iter (Rev_deps.add rev_deps target_path) rev_dep;
        if rule.deps_pending = 0
        then schedule_rule rule
        else Array.iter rule.deps ~f:(schedule ~rev_dep:rule)
      end
    end;
    T.remove visiting target_path
  in

  let process_completed (rule : rule) =
    if rule.is_dyndep then
      Array.iter rule.targets ~f:(fun target ->
      List.iter (Dyndep_file_format.of_file target) ~f:(fun (dyndep : Dyndep_file_format.dyndep) ->
        match T.find_opt t.rules dyndep.target with
        | None ->
          error_occurred := Some (Printf.sprintf "dyndep references unknown target: %s" dyndep.target)
        | Some dep_rule ->
          if dep_rule.scheduled then
            error_occurred := Some (Printf.sprintf
              "dyndep references target that is already scheduled/built: %s" dyndep.target)
          else begin
            dep_rule.dyndeps <- Array.append dep_rule.dyndeps dyndep.deps;
            dep_rule.deps_pending <- dep_rule.deps_pending + Array.length dyndep.deps;
            Array.iter dyndep.deps ~f:(schedule ~rev_dep:dep_rule)
          end));
    Rev_deps.iter rev_deps rule ~f:dep_ready
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

let flatten_uniq_list xss =
  ListLabels.fold_left xss ~init:SS.empty ~f:(fun acc xs ->
    SS.add_seq (List.to_seq xs) acc) |> SS.to_list

module Cmd = struct
  type t = { command: string; deps: string list; targets: string list; }
  let v ?(deps=[]) ?(targets=[]) command = { command; deps; targets }

  let concat' cmds =
    let all_deps = ref [] in
    let all_targets = ref [] in
    let commands =
      List.map cmds ~f:(fun ({ command; deps; targets }) ->
        all_deps := deps :: !all_deps;
        all_targets := targets :: !all_targets;
        command)
    in
    commands, flatten_uniq_list !all_deps, flatten_uniq_list !all_targets

  let concat cmds =
    let commands, deps, targets = concat' cmds in
    { command = String.concat ~sep:" " commands; deps; targets }
end

module Rule = struct
  type t = Build_file_format.stanza list ref

  let create () : t = ref []
  let to_list (t : t) = List.rev !t

  let add' (t : t) stanza = t := stanza :: !t

  let add ?(deps=[]) t commands =
    let commands, deps', targets = Cmd.concat' commands in
    let deps = deps @ deps' in
    add' t (Build_file_format.Rule {
      targets = Array.of_list targets;
      deps = Array.of_list deps;
      commands = Array.of_list commands;
    })

  let add_dyndep ?(deps=[]) t commands =
    let commands, deps', targets = Cmd.concat' commands in
    let deps = deps @ deps' in
    add' t (Build_file_format.Rule_dyndep {
      targets = Array.of_list targets;
      deps = Array.of_list deps;
      commands = Array.of_list commands;
    })
end
