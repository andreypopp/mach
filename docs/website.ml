#!/usr/bin/env mach run
#require "tiny_httpd"
#require "tiny_httpd.unix"
#require "cmarkit"
#require "str"
#require "cmdliner"
#require "./markdown_toc"
#require "./markdown_copy_code"

let script_dir =
  let this_file = __FILE__ in
  Filename.dirname this_file

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let mime_type path =
  match Filename.extension path with
  | ".html" -> "text/html; charset=utf-8"
  | ".css" -> "text/css"
  | ".js" -> "application/javascript"
  | ".json" -> "application/json"
  | ".png" -> "image/png"
  | ".jpg" | ".jpeg" -> "image/jpeg"
  | ".svg" -> "image/svg+xml"
  | ".ico" -> "image/x-icon"
  | ".md" -> "text/markdown"
  | ".woff" -> "font/woff"
  | ".woff2" -> "font/woff2"
  | _ -> "application/octet-stream"

let build_html () =
  let template_path = Filename.concat script_dir "page.template.html" in
  let template = read_file template_path in
  let md_path = Filename.concat script_dir "index.md" in
  let md = read_file md_path in
  let doc = Cmarkit.Doc.of_string ~heading_auto_ids:true md in
  let doc = Markdown_toc.expand doc in
  let renderer =
    let default = Cmarkit_html.renderer ~safe:false () in
    Cmarkit_renderer.compose default Markdown_copy_code.renderer
  in
  let content = Cmarkit_renderer.doc_to_string renderer doc in
  let html = Str.global_replace (Str.regexp_string "{{CONTENT}}") content template in
  html

(* Build command *)
let build_cmd () =
  let html = build_html () in
  let out_path = Filename.concat script_dir "index.html" in
  write_file out_path html;
  Printf.printf "Built %s\n" out_path;
  `Ok ()

(* Serve command *)
let serve_file dir req =
  let path = Tiny_httpd.Request.path req in
  let path = if path = "/" then "/index.html" else path in
  let rel_path = String.sub path 1 (String.length path - 1) in
  let file = Filename.concat dir rel_path in
  if rel_path = "index.html" then
    let body = build_html () in
    Tiny_httpd.Response.make_string
      ~headers:["content-type", mime_type file]
      (Ok body)
  else if Sys.file_exists file && not (Sys.is_directory file) then
    let body = read_file file in
    Tiny_httpd.Response.make_string
      ~headers:["content-type", mime_type file]
      (Ok body)
  else
    Tiny_httpd.Response.make_string (Error (404, "Not found"))

let serve_cmd port =
  let server = Tiny_httpd.create ~port () in
  Tiny_httpd.add_route_handler server
    Tiny_httpd.Route.rest_of_path (fun _path req -> serve_file script_dir req);
  Printf.printf "Serving %s at http://localhost:%d\n%!" script_dir port;
  match Tiny_httpd.run server with
  | Ok () -> `Ok ()
  | Error e -> `Error (false, Printexc.to_string e)

(* CLI *)
open Cmdliner

let port_arg =
  let doc = "Port to serve on." in
  Arg.(value & opt int 8000 & info ["p"; "port"] ~docv:"PORT" ~doc)

let serve_term =
  Term.(ret (const serve_cmd $ port_arg))

let serve_info =
  Cmd.info "serve" ~doc:"Start development server"

let build_term =
  Term.(ret (const build_cmd $ const ()))

let build_info =
  Cmd.info "build" ~doc:"Build index.html from index.md"

let default_term =
  Term.(ret (const (fun () -> `Help (`Pager, None)) $ const ()))

let main_info =
  Cmd.info "website" ~doc:"mach website tools"

let () =
  let serve_cmd = Cmd.v serve_info serve_term in
  let build_cmd = Cmd.v build_info build_term in
  let main_cmd = Cmd.group ~default:default_term main_info [serve_cmd; build_cmd] in
  exit (Cmd.eval main_cmd)
