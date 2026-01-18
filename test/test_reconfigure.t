Test reconfiguration optimization - only reconfigure when dependency graph changes.

  $ . ../env.sh

Create a simple script:

  $ cat << 'EOF' > main.ml
  > let () = print_endline "v1"
  > EOF

First build - should reconfigure (no previous state):

  $ mach run -vv ./main.ml 2>&1
  mach:configure: no previous state found, creating one...
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  v1

Second build without changes - should NOT reconfigure:

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  v1

Content-only change - should NOT reconfigure (Make handles rebuild):

  $ sleep 1
  $ cat << 'EOF' > main.ml
  > let () = print_endline "v2"
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  v2

Add a dependency - SHOULD reconfigure (structural change):

  $ cat << 'EOF' > lib.ml
  > let msg = "from lib"
  > EOF

  $ sleep 1
  $ cat << 'EOF' > main.ml
  > #require "./lib"
  > let () = print_endline Lib.msg
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach:state: requires/libs changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/lib.ml
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  from lib

  $ mach run ./main.ml
  from lib

Content change to dependency - should NOT reconfigure:

  $ sleep 1
  $ cat << 'EOF' > lib.ml
  > let msg = "updated lib"
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  updated lib

  $ mach run ./main.ml
  updated lib

Add .mli file to dependency - SHOULD reconfigure:

  $ cat << 'EOF' > lib.mli
  > val msg : string
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach:state: .mli added/removed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/lib.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  updated lib

Content change to .mli - should NOT reconfigure:

  $ sleep 1
  $ cat << 'EOF' > lib.mli
  > (** The message *)
  > val msg : string
  > EOF

  $ mach run -vv ./main.ml 2>&1
  mach: building...
  updated lib

Remove .mli file - SHOULD reconfigure:

  $ rm lib.mli

  $ mach run -vv ./main.ml 2>&1
  mach:state: .mli added/removed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/lib.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  updated lib
