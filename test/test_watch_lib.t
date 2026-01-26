Test watch mode with libraries.

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

Start watch mode:

  $ mach build -v --watch ./main.ml 2> watch.log &
  $ WATCH_PID=$!

  $ sleep 1

Change content of library module:

  $ cat << 'EOF' > mylib/foo.ml
  > let msg = "v2"
  > EOF

  $ sleep 1

Add a new module to the library:

  $ cat << 'EOF' > mylib/bar.ml
  > let msg2 = "from bar"
  > EOF

  $ sleep 1

Change Machlib file:

  $ printf '\n' >> mylib/Machlib

  $ sleep 1

Remove a module from the library:

  $ rm mylib/bar.ml

  $ sleep 1

  $ kill $WATCH_PID

  $ cat watch.log
  mach: initial build...
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  mach: watching 2 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
    $TESTCASE_ROOT/mylib
  mach: file changed: foo.ml
  mach: building...
  mach: build succeeded
  mach: file changed: bar.ml
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  mach: build succeeded
  mach:watch: reconfigured, restarting watcher...
  mach: watching 2 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
    $TESTCASE_ROOT/mylib
  mach: file changed: Machlib
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  mach: build succeeded
  mach:watch: reconfigured, restarting watcher...
  mach: watching 2 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
    $TESTCASE_ROOT/mylib
  mach: file changed: bar.ml
  mach: configuring library $TESTCASE_ROOT/mylib
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  mach: build succeeded
  mach:watch: reconfigured, restarting watcher...
  mach: watching 2 directories (Ctrl+C to stop):
    $TESTCASE_ROOT
    $TESTCASE_ROOT/mylib
