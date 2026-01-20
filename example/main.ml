#!/usr/bin/env mach run --

#require "cmdliner"
#require "./lib"

open Cmdliner

let () = 
  let doc = "A simple Hello World command-line application." in
  let term = Term.(const Lib.hello_world $ const ()) in
  let cmd = Cmd.v (Cmd.info "hello_world" ~doc) term in
  exit (Cmd.eval cmd)
