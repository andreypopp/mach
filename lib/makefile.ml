(* makefile.ml - Makefile generation backend *)

open Printf

type t = Buffer.t

let create () = Buffer.create 1024

let contents = Buffer.contents

let include_ buf path = bprintf buf "include %s\n" path

let rule buf ~target ~deps recipe =
  bprintf buf "%s:" target;
  List.iter (bprintf buf " %s") deps;
  Buffer.add_char buf '\n';
  List.iter (bprintf buf "\t%s\n") recipe;
  Buffer.add_char buf '\n'

let rulef buf ~target ~deps fmt =
  ksprintf (fun recipe -> rule buf ~target ~deps [recipe]) fmt

let rule_phony buf ~target ~deps =
  bprintf buf ".PHONY: %s\n" target;
  rule buf ~target ~deps []
