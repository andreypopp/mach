(** A simple build system implementation in OCaml. *)

open! Sexplib0.Sexp_conv
open! StdLabels
open! Mach_std

type rule = {
  targets: string array; (** absolute paths of targets rule produces *)
  deps: string array; (** absolute paths of dependencies rule requires *)
  commands: string array; (** a list of shell commands to execute to build the targets *)
} [@@deriving sexp]

type build = {
  rules: rule list;
}

module T = Hashtbl.Make(String)

type build_system = { targets : target T.t; }
and target = {
  rule: rule;
  mutable deps_pending: int;
  mutable built: bool;
}

let create () : build_system =
  { targets = T.create 256; }

let configure {targets;} (b : build) : unit =
  List.iter b.rules ~f:begin fun (rule : rule) ->
    let target = { rule; deps_pending = Array.length rule.deps; built = false } in
    Array.iter rule.targets ~f:(fun t ->
      T.replace targets t target);
  end

let build_target (target : target) =
  if target.built then failwithf "target already built: %s"
    (String.concat ~sep:", " (Array.to_list target.rule.targets));
  assert (target.deps_pending = 0);
  Array.iter target.rule.targets ~f:(fun t ->
    Mach_log.log_verbose "mach: building %s" t);
  let dev_null = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close dev_null) @@ fun () ->
  Array.iter target.rule.commands ~f:begin fun cmd ->
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
  target.built <- true

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

let iter_rev_deps rev_deps target ~f =
  Array.iter target.rule.targets ~f:(fun target_path ->
  match T.find_opt rev_deps target_path with
  | Some targets -> List.iter !targets ~f
  | None -> ())

type build_queue = target Queue.t

let run t ~target_path =
  let queue, rev_deps =
    let queue : build_queue = Queue.create () in (* targets ready to build *)
    let rev_deps : target list ref T.t = T.create 256 in (* next targets to schedule after build of a target *)
    let visiting : unit T.t = T.create 256 in
    let rec schedule ?rev_dep target_path =
      if T.mem visiting target_path then failwithf "dependency cycle detected: %s" target_path;
      if T.mem rev_deps target_path
      then Option.iter (add_rev_dep rev_deps target_path) rev_dep
      else begin
        T.add visiting target_path ();
        let target = T.find t.targets target_path in
        Option.iter (add_rev_dep rev_deps target_path) rev_dep;
        if target.deps_pending = 0
        then Queue.add target queue
        else Array.iter target.rule.deps ~f:(schedule ~rev_dep:target);
        T.remove visiting target_path
      end
    in
    schedule target_path;
    queue, rev_deps
  in
  let rec build () =
    match Queue.take queue with
    | exception Queue.Empty -> ()
    | target ->
      build_target target;
      iter_rev_deps rev_deps target ~f:(fun target ->
        target.deps_pending <- target.deps_pending - 1;
        if target.deps_pending = 0 then Queue.add target queue);
      build ()
  in
  build ()

type stanza = Rule of rule [@@deriving sexp]

let build_of_string s =
  let stanzas = Parsexp.Many.parse_string_exn s |> List.map ~f:stanza_of_sexp in
  let rules = List.filter_map stanzas ~f:(function | Rule r -> Some r) in
  { rules }

let build_of_file file_path =
  let content = In_channel.(with_open_text file_path input_all) in
  build_of_string content

let build ~target_path build =
  let bs = create () in
  configure bs build;
  run bs ~target_path
