(* mach-lsp - LSP support for mach projects *)

open Printf
open Mach_lib

(* --- Merlin server --- *)

module Merlin_server = struct
  module Protocol = Merlin_dot_protocol.Blocking

  (* parses lines -I=<dir> *)
  let parse_includes_args filename =
    if not (Sys.file_exists filename) then []
    else In_channel.with_open_text filename (fun ic ->
      let rec read_lines acc =
        match In_channel.input_line ic with
        | None -> List.rev acc
        | Some line ->
          read_lines @@
            if String.starts_with line ~prefix:"-I="
            then String.sub line 3 (String.length line - 3) :: acc
            else acc
      in
      read_lines [])

  let directives_for_file path : Merlin_dot_protocol.directive list =
    try
      let path = Unix.realpath path in
      let build_dir = build_dir_of path in
      match extract_requires path with
      | Error `User_error msg -> [`ERROR_MSG msg]
      | Ok (~requires, ~libs:_) ->
      let dep_dirs = parse_includes_args (Filename.concat build_dir "includes.args") in
      let lib_dirs = parse_includes_args (Filename.concat build_dir "lib_includes.args") in
      let directives = [] in
      let directives =
        if lib_dirs = [] then directives
        else
          let lib_flags = List.concat_map (fun p -> ["-I"; p]) lib_dirs in
          (`FLG lib_flags) :: directives
      in
      let directives =
        List.fold_left (fun directives (dep_dir : string) ->
          let include_flags = ["-I"; dep_dir] in
          let directives = `CMT build_dir :: `B build_dir :: directives in
          let directives = if include_flags = [] then directives else (`FLG include_flags)::directives in
          directives
        ) directives dep_dirs
      in
      let directives =
        List.fold_left (fun directives require ->
          `S (Filename.dirname require)::directives
        ) directives requires
      in
      let directives = `S (Filename.dirname path) :: directives in
      `FLG ["-pp"; "mach pp"] :: directives
    with
    | Failure msg -> [`ERROR_MSG msg]
    | Unix.Unix_error (err, _, arg) ->
      [`ERROR_MSG (sprintf "%s: %s" (Unix.error_message err) arg)]
    | _ -> [`ERROR_MSG "Unknown error computing merlin config"]

  let run () =
    let rec loop () =
      match Protocol.Commands.read_input stdin with
      | Halt -> ()
      | Unknown -> loop ()
      | File path ->
        let directives = directives_for_file path in
        Protocol.write stdout directives;
        flush stdout;
        loop ()
    in
    loop ()
end

(* --- Start ocamllsp --- *)

let start_lsp () =
  (* Find ocamllsp binary *)
  let ocamllsp_path =
    let paths = String.split_on_char ':' (Sys.getenv_opt "PATH" |> Option.value ~default:"") in
    let rec find = function
      | [] ->
        eprintf "mach-lsp: ocamllsp not found in PATH\n%!";
        exit 1
      | dir :: rest ->
        let path = Filename.concat dir "ocamllsp" in
        if Sys.file_exists path then path else find rest
    in
    find paths
  in
  (* Find mach-lsp binary (ourselves) *)
  let mach_lsp_path = Unix.realpath Sys.executable_name in
  (* Set OCAML_MERLIN_BIN and exec ocamllsp *)
  Unix.putenv "OCAMLLSP_PROJECT_BUILD_SYSTEM" mach_lsp_path;
  Unix.execv ocamllsp_path [| ocamllsp_path |]

(* --- CLI --- *)

open Cmdliner

let ocaml_merlin_cmd =
  let doc = "Merlin configuration server (called by ocamllsp)" in
  let info = Cmd.info "ocaml-merlin" ~doc in
  Cmd.v info Term.(const Merlin_server.run $ const ())

let cmd =
  let doc = "Start OCaml LSP server with mach support" in
  let info = Cmd.info "mach-lsp" ~doc in
  let default = Term.(const start_lsp $ const ()) in
  Cmd.group ~default info [ocaml_merlin_cmd]

let () = exit (Cmdliner.Cmd.eval cmd)
