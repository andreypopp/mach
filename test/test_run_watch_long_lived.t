Test run watch mode with long-lived program that gets killed on rebuild:
  $ cat << 'EOF' > server.ml
  > #require "unix"
  > let () =
  >   Printf.eprintf "server v1 started, (pid %d)\n%!" (Unix.getpid ());
  >   Unix.sleep 60
  > EOF

  $ mach run -v --watch ./server.ml 2> watch.log &
  $ WATCH_PID=$!

  $ sleep 2

  $ cat << 'EOF' > server.ml
  > #require "unix"
  > let () =
  >   Printf.eprintf "server v2 started, (pid %d)\n%!" (Unix.getpid ());
  >   Unix.sleep 60
  > EOF

  $ sleep 2

  $ kill $WATCH_PID

  $ sleep 1

Check watch log:
  $ cat watch.log | sed -E 's/pid [0-9]+/pid PID/g'
  mach: initial build...
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/server.ml
  mach: configuring $TESTCASE_ROOT/server.ml (root)
  mach: building...
  mach: starting $TESTCASE_ROOT/server.ml
  mach: watching 1 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
  server v1 started, (pid PID)
  mach: file changed: server.ml
  mach: building...
  mach: build succeeded
  mach: stopping previous instance (pid PID)...
  mach: starting $TESTCASE_ROOT/server.ml
  server v2 started, (pid PID)
