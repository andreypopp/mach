Test auto-derived build directory (uses script path to derive build dir location):

  $ cat << 'EOF' > lib.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib"
  > let () = Lib.greet "World"
  > EOF

Set XDG_CONFIG_HOME to control where build directory is created:

  $ . ../env.sh

First run - creates build directory:

  $ mach run ./main.ml
  Hello, World!

Check that build directory was created (path contains normalized script path with __):

  $ ls _mach/build/*main.ml/ | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  Mach.state
  a.out
  all_objects.args
  includes.args
  main.cmi
  main.cmt
  main.cmx
  main.ml
  main.o

Second run - reuses the same build directory:

  $ mach run ./main.ml
  Hello, World!

Verify build artifacts exist in the auto-derived directory:

  $ ls _mach/build/*main.ml/ | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  Mach.state
  a.out
  all_objects.args
  includes.args
  main.cmi
  main.cmt
  main.cmx
  main.ml
  main.o
