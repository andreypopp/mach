{
open! Mach_std

type token =
  | TARGET of string Non_empty_list.t
  | DEP of concat Non_empty_list.t
  | CMD_FRAGMENT of concat
  | LITERAL of string
  | PERCENT
  | EOF
and concat =
  | CONCAT of string
  | ONE of string

let split_on_pipe s =
  String.split_on_char '|' s |> List.map String.trim

let parse_concat s =
  if String.ends_with s ~suffix:"..."
  then CONCAT (String.sub s 0 (String.length s - 3))
  else ONE s
}

let ws = [' ' '\t']*
let ident = ['a'-'z' 'A'-'Z' '_']['a'-'z' 'A'-'Z' '0'-'9' '_' '\'']*
let ident_or_list = ident "..."?
let target_names = ws ident (ws '|' ws ident)* ws
let dep_names = ws '|'? ws ident_or_list (ws '|' ws ident_or_list)* ws
let cmd_name = ws ident_or_list ws

rule token = parse
  | ">{" (target_names as names) "}"  { TARGET (Non_empty_list.of_list (split_on_pipe names)) }
  | "<{" (dep_names as names) "}"     { DEP (Non_empty_list.of_list (List.map parse_concat (split_on_pipe names))) }
  | "%{" (cmd_name as name) "}"       { CMD_FRAGMENT (parse_concat (String.trim name)) }
  | '%'                           { PERCENT }
  | [^'>' '<' '%']+ as s          { LITERAL s }
  | '>' | '<'                     { LITERAL (Lexing.lexeme lexbuf) }
  | eof                           { EOF }
