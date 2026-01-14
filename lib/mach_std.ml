(** Standard utility functions used across the Mach code. *)

open Printf

module Filename = struct
  include Filename
  let (/) = concat
end

module Buffer = struct
  include Buffer
  let output_line oc line = output_string oc line; output_char oc '\n'
end

module SS = Set.Make(String)

type 'a with_loc = { v: 'a; filename: string; line: int }

let equal_without_loc a b = a.v = b.v

let failwithf fmt = ksprintf failwith fmt

let run_cmd cmd =
  let ic = Unix.open_process_in cmd in
  let output = try Some (input_line ic) with End_of_file -> None in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> output
  | _ -> None

let run_cmd_lines cmd =
  let ic = Unix.open_process_in cmd in
  let lines = In_channel.input_lines ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> lines
  | _ -> []

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let rm_rf path =
  let cmd = sprintf "rm -rf %s" (Filename.quote path) in
  if Sys.command cmd <> 0 then failwithf "Command failed: %s" cmd

let write_file path content =
  Out_channel.with_open_text path (fun oc -> output_string oc content)
