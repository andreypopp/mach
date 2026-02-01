{
type token =
  | TARGET of string list
  | DEP of string list
  | CMD_FRAGMENT of string
  | CMD_FRAGMENT_LIST of string
  | LITERAL of string
  | PERCENT
  | EOF

let split_on_pipe s =
  String.split_on_char '|' s |> List.map String.trim

let ends_with_ellipsis s =
  String.length s >= 3 && String.sub s (String.length s - 3) 3 = "..."

let strip_ellipsis s =
  String.sub s 0 (String.length s - 3)
}

rule token = parse
  | ">{" ([^'}']+ as names) "}"  { TARGET (split_on_pipe names) }
  | "<{" ([^'}']+ as names) "}"  { DEP (split_on_pipe names) }
  | "%{" ([^'}']+ as name) "}"   {
      let name = String.trim name in
      if ends_with_ellipsis name then
        CMD_FRAGMENT_LIST (strip_ellipsis name)
      else
        CMD_FRAGMENT name
    }
  | '%'                           { PERCENT }
  | [^'>' '<' '{' '%']+ as s      { LITERAL s }
  | '>' | '<'                     { LITERAL (Lexing.lexeme lexbuf) }
  | eof                           { EOF }
