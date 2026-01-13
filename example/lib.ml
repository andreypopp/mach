#!/usr/bin/env mach run
#require "./a.ml";;
#require "./b.ml";;

let hello_world () =
  A.a ();
  B.b ();
  print_endline "Hello, World! from lib"
