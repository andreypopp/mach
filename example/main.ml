#!/usr/bin/env mach run --

#require "cmdliner"
#require "./lib.ml"

open Cmdliner

let () =
  Lib.hello_world ()

let () = print_endline "sss"
