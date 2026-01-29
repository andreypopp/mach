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
    Out_channel.(with_open_text file_path (fun oc -> output_string oc s))
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
    Out_channel.(with_open_text file_path (fun oc -> output_string oc s))
end

module T = Hashtbl.Make(String)

type t = { rules : rule T.t; }

and rule = {
  deps : string array;
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
    let rule = { target; deps; commands; deps_pending = Array.length deps; built = false } in
    Array.iter (rule_targets rule) ~f:(fun target ->
      T.replace t.rules target rule))

let build_rule (rule : rule) =
  let targets = rule_targets rule in
  if rule.built then failwithf "target already built: %s"
    (String.concat ~sep:", " (Array.to_list targets));
  assert (rule.deps_pending = 0);
  Array.iter targets ~f:(fun t ->
    Mach_log.log_verbose "mach: building %s" t);
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
        ignore (Unix.write Unix.stdout buf 0 n);
        read_loop ()
      end
    in
    read_loop ();
    let _, status = Unix.waitpid [] pid in
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED n -> failwithf "command failed with exit code %d: %s" n cmd
    | Unix.WSIGNALED n -> failwithf "command killed by signal %d: %s" n cmd
    | Unix.WSTOPPED n -> failwithf "command stopped by signal %d: %s" n cmd
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

let build t ~target_path =
  let queue : build_queue = Queue.create () in (* targets ready to build *)
  let rev_deps : rule list ref T.t = T.create 256 in (* next targets to schedule after build of a target *)
  let visiting : unit T.t = T.create 256 in
  let rec schedule ?rev_dep target_path =
    if T.mem visiting target_path then failwithf "dependency cycle detected: %s" target_path;
    T.add visiting target_path ();
    begin match T.find_opt t.rules target_path with
    | None -> (* not a target we know about, a source file perhaps, just notify rev_deps *)
      Option.iter (fun rule ->
        rule.deps_pending <- rule.deps_pending - 1;
        if rule.deps_pending = 0 then Queue.add rule queue) rev_dep
    | Some rule ->
      if T.mem rev_deps target_path
      then Option.iter (add_rev_dep rev_deps target_path) rev_dep
      else begin
          Option.iter (add_rev_dep rev_deps target_path) rev_dep;
          if rule.deps_pending = 0
          then Queue.add rule queue
          else Array.iter rule.deps ~f:(schedule ~rev_dep:rule)
      end
    end;
    T.remove visiting target_path
  in
  let rec build () =
    match Queue.take queue with
    | exception Queue.Empty -> ()
    | rule ->
      build_rule rule;
      (* Handle dyndeps: after building a dyndep target, load additional deps
         and add them to targets that depend on this dyndep *)
      begin match rule.target with
      | Targets _ -> ()
      | Target_dyndep target ->
        List.iter (Dyndep_file_format.of_file target) ~f:(fun (dyndep : Dyndep_file_format.dyndep) ->
          match T.find_opt t.rules dyndep.target with
          | None -> failwithf "dyndep references unknown target: %s" dyndep.target
          | Some dep_rule ->
            if dep_rule.deps_pending = 0 then
              failwithf "dyndep references target that is already scheduled/built: %s" dyndep.target;
            dep_rule.deps_pending <- dep_rule.deps_pending + Array.length dyndep.deps;
            Array.iter dyndep.deps ~f:(schedule ~rev_dep:dep_rule))
      end;
      iter_rev_deps rev_deps rule ~f:(fun rule ->
        rule.deps_pending <- rule.deps_pending - 1;
        if rule.deps_pending = 0 then Queue.add rule queue);
      build ()
  in
  schedule target_path;
  build ()
