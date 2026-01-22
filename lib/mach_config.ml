(* mach_config - Mach configuration discovery and parsing *)

open! Mach_std
open Sexplib0.Sexp_conv
open Printf

(* --- Toolchain detection --- *)

type ocamlfind_info = {
  ocamlfind_version: string option;
  ocamlfind_libs: string SM.t;  (* package name -> version *)
}

type toolchain = {
  ocaml_version: string;
  ocamlfind: ocamlfind_info Lazy.t;
}

let detect_ocamlfind () =
  if command_exists "ocamlfind" then
    let version = run_cmd "ocamlfind query -format '%v' findlib" in
    let libs =
      run_cmd_lines "ocamlfind list"
      |> List.fold_left (fun acc line ->
           match Scanf.sscanf_opt line "%s %_s@(version: %[^)])" (fun n v -> n, v) with
           | Some (name, ver) -> SM.add name ver acc
           | None -> failwithf "unable to parse `ocamlfind list` line: %s" line)
         SM.empty
    in
    { ocamlfind_version = version; ocamlfind_libs = libs }
  else
    { ocamlfind_version = None; ocamlfind_libs = SM.empty }

let detect_toolchain () =
  let ocaml_version =
    match run_cmd "ocamlopt -version" with
    | Some v -> v
    | None -> Mach_error.user_errorf "ocamlopt not found"
  in
  { ocaml_version; ocamlfind = lazy (detect_ocamlfind ()) }

(* --- Config type and parsing --- *)

type t = {
  home: string;
  mach_executable_path: string;
  toolchain: toolchain;
}

(* Config file sexp format *)
type config_file = unit [@@deriving sexp]

let mach_executable_path =
  lazy (
    match Sys.backend_type with
    | Sys.Native -> Unix.realpath Sys.executable_name
    | Sys.Bytecode ->
      let script =
        let path = Sys.argv.(0) in
        if Filename.is_relative path then Filename.(Sys.getcwd () / path) else path
      in
      sprintf "%s -I +unix unix.cma %s"
        (Filename.quote Sys.executable_name) (Filename.quote (Unix.realpath script))
    | Sys.Other _ -> failwith "mach must be run as a native/bytecode executable"
  )

let parse_file path =
  try
    let content = In_channel.with_open_text path In_channel.input_all in
    let sexp = Parsexp.Single.parse_string_exn content in
    Ok (config_file_of_sexp sexp)
  with exn ->
    Error (`User_error (sprintf "%s: %s" path (Printexc.to_string exn)))

let find_mach_config () =
  let rec search dir =
    let mach_path = Filename.(dir / "Mach") in
    if Sys.file_exists mach_path then Some (dir, mach_path)
    else
      let parent = Filename.dirname dir in
      if parent = dir then None
      else search parent
  in
  search (Sys.getcwd ())

let make_config ?mach_path home =
  let mach_executable_path = Lazy.force mach_executable_path in
  let toolchain = detect_toolchain () in
  let mach_path = Option.value mach_path ~default:Filename.(home / "Mach") in
  if Sys.file_exists mach_path then
    match parse_file mach_path with
    | Ok () -> Ok { home; mach_executable_path; toolchain }
    | Error _ as err -> err
  else
    Ok { home; mach_executable_path; toolchain }

let config =
  lazy (
    match Sys.getenv_opt "MACH_HOME" with
    | Some home -> make_config home
    | None ->
      match find_mach_config () with
      | Some (home, mach_path) -> make_config ~mach_path home
      | None ->
        let home = match Sys.getenv_opt "XDG_STATE_HOME" with
          | Some xdg -> Filename.(xdg / "mach")
          | None -> Filename.(Sys.getenv "HOME" / ".local" / "state" / "mach")
        in
        make_config home)

let get () = Lazy.force config

let build_dir_of config script_path =
  let normalized = String.split_on_char '/' script_path |> String.concat "__" in
  Filename.(config.home / "_mach" / "build" / normalized)
