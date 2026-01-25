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

let print_deps buf ~deps ~order_only_deps =
  List.iter (bprintf buf " %s") deps;
  (match order_only_deps with | [] -> () | deps -> bprintf buf " ||"; List.iter (bprintf buf " %s") deps)

let rule buf ~target ~deps ?(order_only_deps=[]) ?dyndep recipe =
  let order_only_deps =
    match dyndep with
    | None -> order_only_deps
    | Some dyndep -> dyndep :: order_only_deps
  in
  bprintf buf "build %s:" target;
  (match recipe with
  | [] ->
    bprintf buf " phony"; print_deps buf ~deps ~order_only_deps; Buffer.add_char buf '\n'
  | _ ->
    bprintf buf " cmd"; print_deps buf ~deps ~order_only_deps; Buffer.add_char buf '\n';
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
