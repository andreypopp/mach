  $ . ../env.sh

Prepare source files:
  $ cat << 'EOF' > hello.ml
  > print_endline "hello"
  > EOF

Test watch mode with verbose flag shows initial build:
  $ mach build -v --watch ./hello.ml 2> watch.log &
  $ WATCH_PID=$!

  $ sleep 1

  $ cat << 'EOF' > hello.ml
  > print_endline "hello1"
  > EOF

  $ sleep 1

  $ kill $WATCH_PID

  $ cat watch.log
  mach: initial build...
  mach: configuring...
  mach: building...
  mach: watching 1 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
  mach: file changed: hello.ml
  mach: building...
  mach: build succeeded

