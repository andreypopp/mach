Create a script that uses cmdliner:
  $ cat << 'EOF' > main.ml
  > #require "cmdliner";;
  > 
  > let () =
  >   let open Cmdliner in
  >   let name = Arg.(value & opt string "World" & info ["n"; "name"] ~doc:"Name to greet") in
  >   let greet name = Printf.printf "Hello, %s!\n" name in
  >   let cmd = Cmd.v (Cmd.info "greet") Term.(const greet $ name) in
  >   exit (Cmd.eval cmd)
  > EOF

Test basic run:
  $ mach run ./main.ml
  Hello, World!

Test with argument:
  $ mach run ./main.ml -- -n Claude
  Hello, Claude!

Start with a script without libs:
  $ rm -rf _mach
  $ cat << 'EOF' > simple.ml
  > let () = print_endline "no libs"
  > EOF

  $ mach run -vv ./simple.ml 2>&1
  mach:configure: no previous state found, creating one...
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/simple.ml
  mach: configuring $TESTCASE_ROOT/simple.ml (root)
  mach: building...
  no libs

Add a lib - SHOULD reconfigure:
  $ sleep 1
  $ cat << 'EOF' > simple.ml
  > #require "cmdliner";;
  > let () = print_endline "with cmdliner"
  > EOF

  $ mach run -vv ./simple.ml 2>&1
  mach:state:$TESTCASE_ROOT/simple.ml:module requires changed
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/simple.ml
  mach: configuring $TESTCASE_ROOT/simple.ml (root)
  mach: building...
  with cmdliner

Remove the lib - SHOULD reconfigure:
  $ sleep 1
  $ cat << 'EOF' > simple.ml
  > let () = print_endline "libs removed"
  > EOF

  $ mach run -vv ./simple.ml 2>&1
  mach:state:$TESTCASE_ROOT/simple.ml:module requires changed
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/simple.ml
  mach: configuring $TESTCASE_ROOT/simple.ml (root)
  mach: building...
  libs removed
