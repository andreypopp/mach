Isolate mach config to a test dir:
  $ . ../env.sh

Test MACH_BUILD_BACKEND env var:
  $ cat << 'EOF' > env_test.ml
  > print_endline "env test"
  > EOF
  $ MACH_BUILD_BACKEND=ninja mach run ./env_test.ml 2>&1 | grep -v "^\[" | grep -v "^ninja:"
  env test
  $ test -f mach/build/*__env_test.ml/build.ninja && echo "ninja files created"
  ninja files created
  $ rm -rf mach

Prepare source files:
  $ cat << 'EOF' > lib.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = Lib.greet "World"
  > EOF

Test with ninja backend (filter out ninja's progress output):
  $ mach run --build-backend ninja ./main.ml 2>&1 | grep -v "^\[" | grep -v "^ninja:"
  Hello, World!

Inspect the build dir - check for ninja files instead of Makefile:
  $ ls mach/build/*__lib.ml | sort
  includes.args
  lib.cmi
  lib.cmt
  lib.cmx
  lib.ml
  lib.o
  mach.ninja

  $ ls mach/build/*__main.ml | sort
  Mach.state
  a.out
  all_objects.args
  build.ninja
  includes.args
  mach.ninja
  main.cmi
  main.cmt
  main.cmx
  main.ml
  main.o

Check build.ninja uses subninja to include the dependency:
  $ grep -q "subninja.*mach.ninja" mach/build/*__main.ml/build.ninja && echo "includes dependency"
  includes dependency

Verify mach.ninja has the cmd rule (each file has its own scoped rules):
  $ grep -q "^rule cmd" mach/build/*__lib.ml/mach.ninja && echo "has cmd rule"
  has cmd rule
