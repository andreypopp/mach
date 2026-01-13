(* mach_config - Mach configuration discovery and parsing *)

open Printf

module Filename = struct
  include Filename
  let (/) = concat
end

(* --- Build backend types --- *)

type build_backend = Make | Ninja

let string_of_build_backend = function Make -> "make" | Ninja -> "ninja"
let build_backend_of_string = function
  | "make" -> Make
  | "ninja" -> Ninja
  | s -> failwith (sprintf "unknown build backend: %s" s)

(* --- Config type and parsing --- *)

type error = [`User_error of string]

type t = {
  home: string;
  build_backend: build_backend;
}

let default_build_backend = Make

let parse_file path =
  In_channel.with_open_text path (fun ic ->
    let rec loop build_backend line_num =
      match In_channel.input_line ic with
      | None -> Ok build_backend
      | Some line ->
        let line = String.trim line in
        if line = "" || String.starts_with ~prefix:"#" line then
          loop build_backend (line_num + 1)
        else
          match Scanf.sscanf_opt line "%s %S" (fun k v -> k, v) with
          | None ->
            Error (`User_error (sprintf "%s:%d: malformed line" path line_num))
          | Some (key, value) ->
            match key with
            | "build-backend" ->
              (try
                let build_backend = build_backend_of_string value in
                loop build_backend (line_num + 1)
              with Failure msg ->
                Error (`User_error (sprintf "%s:%d: %s" path line_num msg)))
            | _ ->
              Error (`User_error (sprintf "%s:%d: unknown key: %s" path line_num key))
    in
    loop default_build_backend 1)

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

let make_config home =
  let mach_path = Filename.(home / "Mach") in
  if Sys.file_exists mach_path then
    match parse_file mach_path with
    | Ok build_backend -> Ok { home; build_backend }
    | Error _ as err -> err
  else
    Ok { home; build_backend = default_build_backend }

let config =
  lazy (
    match Sys.getenv_opt "MACH_HOME" with
    | Some home -> make_config home
    | None ->
      match find_mach_config () with
      | Some (home, mach_path) ->
        (match parse_file mach_path with
        | Ok build_backend -> Ok { home; build_backend }
        | Error _ as err -> err)
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
