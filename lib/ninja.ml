(* ninja.ml - Ninja build backend *)

open Printf

type t = Buffer.t

let create () =
  let buf = Buffer.create 1024 in
  bprintf buf "rule cmd\n  command = $cmd\n\n";
  buf

let var buf name value =
  bprintf buf "%s = %s\n\n" name value

let contents = Buffer.contents

let subninja buf path = bprintf buf "subninja %s\n" path

let rule buf ~target ~deps ?dyndep recipe =
  bprintf buf "build %s:" target;
  (match recipe with
  | [] ->
    bprintf buf " phony";
    List.iter (bprintf buf " %s") deps;
    Buffer.add_char buf '\n'
  | _ ->
    bprintf buf " cmd";
    List.iter (bprintf buf " %s") deps;
    Buffer.add_char buf '\n';
    bprintf buf "  cmd = %s\n" (String.concat " && " recipe);
    Option.iter (bprintf buf "  dyndep = %s\n") dyndep);
  Buffer.add_char buf '\n'

let rulef buf ~target ~deps fmt =
  ksprintf (fun recipe -> rule buf ~target ~deps [recipe]) fmt

let rule_phony buf ~target ~deps =
  bprintf buf "build %s: phony" target;
  List.iter (bprintf buf " %s") deps;
  Buffer.add_char buf '\n';
  Buffer.add_char buf '\n'
