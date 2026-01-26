Prepare source file with syntax error:
  $ cat << 'EOF' > hello.ml
  > print_endline "hello
  > EOF

Test watch mode continues even if initial build fails:
  $ mach build -v --watch ./hello.ml 2> watch.log &
  $ WATCH_PID=$!

Give it time to attempt initial build and start watching:
  $ sleep 2

Process should still be running (check before fixing):
  $ kill -0 $WATCH_PID 2>/dev/null && echo "still running"
  still running

Fix the syntax error:
  $ cat << 'EOF' > hello.ml
  > print_endline "hello"
  > EOF

Wait for rebuild:
  $ sleep 2

Stop the watcher:
  $ kill $WATCH_PID

Check the log shows initial failure then successful rebuild:
  $ cat watch.log
  mach: initial build...
  mach: configuring $TESTCASE_ROOT/hello.ml
  mach: configuring $TESTCASE_ROOT/hello.ml (root)
  mach: building...
  File "$TESTCASE_ROOT/hello.ml", line 1, characters 14-15:
  Error: String literal not terminated
  mach: build failed
  mach: watching 1 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
  mach: file changed: hello.ml
  mach: building...
  mach: build succeeded

