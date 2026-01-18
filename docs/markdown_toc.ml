#!/usr/bin/env mach run
#require "cmarkit"
(* Table of Contents generation for cmarkit documents *)

let collect_headings doc =
  let open Cmarkit in
  let block _f acc = function
    | Block.Heading (h, _meta) ->
        let level = Block.Heading.level h in
        let inline = Block.Heading.inline h in
        let id = Block.Heading.id h in
        Folder.ret ((level, inline, id) :: acc)
    | _ -> Folder.default
  in
  let folder = Folder.make ~block () in
  List.rev (Folder.fold_doc folder [] doc)

let inline_to_text inline =
  let lines = Cmarkit.Inline.to_plain_text ~break_on_soft:false inline in
  String.concat " " (List.map (String.concat "") lines)

let render_toc_html headings =
  let buf = Buffer.create 256 in
  let add fmt = Printf.ksprintf (Buffer.add_string buf) fmt in
  let rec render_items items depth =
    match items with
    | [] -> depth
    | (level, inline, id) :: rest ->
        let depth =
          if depth = 0 then begin
            add {|<ul class="toc">|};
            1
          end else depth
        in
        add {|<li data-toc-level="%d">|} level;
        let text = inline_to_text inline in
        (match id with
        | Some (`Auto s | `Id s) ->
            add {|<a href="#%s">|} s;
            Cmarkit_html.buffer_add_html_escaped_string buf text;
            add "</a>"
        | None ->
            Cmarkit_html.buffer_add_html_escaped_string buf text);
        add "</li>";
        render_items rest depth
  in
  if headings <> [] then begin
    let depth = render_items headings 0 in
    for _ = 1 to depth do add "</ul>\n" done
  end;
  Buffer.contents buf

let is_toc_tag text = String.trim text = "<toc>"

let expand doc =
  let open Cmarkit in
  let headings = collect_headings doc in
  let toc_html = render_toc_html headings in
  let inline _m = function
    | Inline.Raw_html (lines, meta) ->
        let text = String.concat "" (List.map (fun (blanks, (s, _)) -> blanks ^ s) lines) in
        if is_toc_tag text then
          let toc_lines = Block_line.tight_list_of_string toc_html in
          Mapper.ret (Inline.Raw_html (toc_lines, meta))
        else
          Mapper.default
    | _ -> Mapper.default
  in
  let block _m = function
    | Block.Html_block (lines, meta) ->
        let text = String.concat "" (List.map (fun (s, _) -> s) lines) in
        if is_toc_tag text then
          let toc_lines = Block_line.list_of_string toc_html in
          Mapper.ret (Block.Html_block (toc_lines, meta))
        else Mapper.default
    | _ -> Mapper.default
  in
  let mapper = Mapper.make ~inline ~block () in
  Mapper.map_doc mapper doc
