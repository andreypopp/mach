(* mach-lsp - LSP support for mach projects *)

open Printf
open Mach_lib

(* --- Merlin server --- *)

module Merlin_server = struct
  module Protocol = Merlin_dot_protocol.Blocking

  (* Query ocamlfind for library include paths *)
  let query_lib_includes libs =
    if libs = [] then []
    else
      let libs_str = String.concat " " libs in
      let cmd = sprintf "ocamlfind query -format '%%d' -recursive %s 2>/dev/null" libs_str in
      let ic = Unix.open_process_in cmd in
      let rec read_lines acc =
        match In_channel.input_line ic with
        | None -> List.rev acc
        | Some line -> read_lines (line :: acc)
      in
      let paths = read_lines [] in
      ignore (Unix.close_process_in ic);
      paths

  let directives_for_file path : Merlin_dot_protocol.directive list =
    try
      let path = Unix.realpath path in
      let build_dir = build_dir_of path in
      let state_path = Filename.concat build_dir "Mach.state" in
      let state =
        match Mach_state.read state_path with
        | Some st -> Ok st
        | None -> Error "please run 'mach build SCRIPT' first"
      in
      match state with
      | Error msg -> [`ERROR_MSG msg]
      | Ok state ->
      let directives = [] in
      let directives =
        List.fold_left
          (fun directives source_dir -> (`S source_dir)::directives)
          directives (Mach_state.source_dirs state)
      in
      (* Add -I flags for ocamlfind libraries *)
      let lib_paths = query_lib_includes (Mach_state.all_libs state) in
      let directives =
        if lib_paths = [] then directives
        else
          let lib_flags = List.concat_map (fun p -> ["-I"; p]) lib_paths in
          (`FLG lib_flags) :: directives
      in
      let directives =
        List.fold_left (fun directives (entry : Mach_state.entry) ->
          let build_dir = build_dir_of entry.ml_path in
          let source_dir = Filename.dirname entry.ml_path in
          (* Add -I flags for each dependency's build directory *)
          let include_flags = List.map (fun dep -> "-I" :: build_dir_of dep :: []) entry.requires in
          let include_flags = List.flatten include_flags in
          let directives = `CMT build_dir :: `B build_dir :: `S source_dir :: directives in
          let directives = if include_flags = [] then directives else (`FLG include_flags)::directives in
          directives
        ) directives state.entries
      in
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
