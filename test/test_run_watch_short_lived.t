  $ . ../env.sh

Test run watch mode with short-lived program:
  $ cat << 'EOF' > hello.ml
  > let () = prerr_endline "v1"
  > EOF

  $ mach run -v --watch ./hello.ml 2> watch.log &
  $ WATCH_PID=$!

  $ sleep 2

  $ cat << 'EOF' > hello.ml
  > let () = prerr_endline "v2"
  > EOF

  $ sleep 2

  $ kill $WATCH_PID

  $ sleep 1

Check the watch log:
  $ cat watch.log
  mach: initial build...
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/hello.ml
  mach: configuring $TESTCASE_ROOT/hello.ml (root)
  mach: building...
  mach: starting $TESTCASE_ROOT/hello.ml
  mach: watching 1 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
  v1
  mach: file changed: hello.ml
  mach: building...
  mach: build succeeded
  mach: starting $TESTCASE_ROOT/hello.ml
  v2
