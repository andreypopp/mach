Isolate mach config to a test dir:
  $ source ../env.sh

Prepare source files:
  $ cat << 'EOF' > lib.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = Lib.greet "World"
  > EOF

Test:
  $ mach run ./main.ml
  Hello, World!

Inspect the build dir:
  $ ls mach/build/*__lib.ml | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  includes.args
  lib.cmi
  lib.cmo
  lib.cmt
  lib.ml

  $ ls mach/build/*__main.ml | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  Mach.state
  a.out
  all_objects.args
  includes.args
  main.cmi
  main.cmo
  main.cmt
  main.ml
