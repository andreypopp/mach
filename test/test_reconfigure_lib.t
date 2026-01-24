Test reconfiguration optimization for libraries.

Create a library with one module:

  $ mkdir -p mylib
  $ cat << 'EOF' > mylib/foo.ml
  > let msg = "v1"
  > EOF

  $ cat << 'EOF' > mylib/Machlib
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () = print_endline Foo.msg
  > EOF

First build - should reconfigure (no previous state):

  $ mach run -vv ./main.ml 2>&1
  mach:configure: no previous state found, creating one...
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  v1

Second build without changes - should NOT reconfigure:

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  v1

Content-only change to library module - should NOT reconfigure:

  $ sleep 1
  $ cat << 'EOF' > mylib/foo.ml
  > let msg = "v2"
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  v2

Modify Machlib file - SHOULD reconfigure:

  $ sleep 1
  $ printf '\n' >> mylib/Machlib

  $ mach run -vv ./main.ml 2>&1
  mach:state:$TESTCASE_ROOT/mylib:Machlib file changed
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  v2

Add a new module to the library - SHOULD reconfigure:

  $ sleep 1
  $ cat << 'EOF' > mylib/bar.ml
  > let msg2 = "from bar"
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach:state:$TESTCASE_ROOT/mylib:library directory changed
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  v2

Use the new module (content change only - should NOT reconfigure):

  $ sleep 1
  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () = print_endline (Foo.msg ^ " " ^ Bar.msg2)
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  v2 from bar

Remove a module from the library - SHOULD reconfigure:

  $ rm mylib/bar.ml

  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () = print_endline Foo.msg
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach:state:$TESTCASE_ROOT/mylib:library directory changed
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  v2
