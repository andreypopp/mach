Test toolchain version tracking in state file.

Create a simple script:

  $ cat << 'EOF' > main.ml
  > let () = print_endline "hello"
  > EOF

Build it:

  $ mach run ./main.ml
  hello

Verify state file contains ocaml_version and ocamlfind_version in header:

  $ grep -c '^ocaml_version ' _mach/build/*__main.ml/Mach.state
  1
  $ grep -c '^ocamlfind_version ' _mach/build/*__main.ml/Mach.state
  1

No reconfigure on subsequent run:

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  hello

Test that modifying ocaml_version in state triggers reconfigure:

  $ sed -i.bak 's/^ocaml_version .*/ocaml_version 1.0.0/' _mach/build/*__main.ml/Mach.state

  $ mach run -vv ./main.ml 2>&1
  mach:state: environment changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  hello

Test that modifying ocamlfind_version in state triggers reconfigure:

  $ sed -i.bak 's/^ocamlfind_version .*/ocamlfind_version 0.0.0/' _mach/build/*__main.ml/Mach.state

  $ mach run -vv ./main.ml 2>&1
  mach:state: environment changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  hello

No reconfigure on subsequent run:

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  hello
