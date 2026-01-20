Prepare source files:
  $ cat << 'EOF' > lib.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib"
  > let () = Lib.greet "World"
  > EOF

Test:
  $ mach run ./main.ml
  Hello, World!

Inspect the build dir:
  $ ls _mach/build/*__lib.ml | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  includes.args
  lib.cmi
  lib.cmt
  lib.cmx
  lib.ml
  lib.o

  $ ls _mach/build/*__main.ml | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  Mach.state
  a.out
  all_objects.args
  includes.args
  main.cmi
  main.cmt
  main.cmx
  main.ml
  main.o

Test absolute path resolution (extension is inferred for absolute paths too):
  $ cat << 'EOF' > abs_lib.ml
  > let message = "from absolute path"
  > EOF

  $ cat << EOF > main_abs.ml
  > #require "$PWD/abs_lib"
  > let () = print_endline Abs_lib.message
  > EOF

  $ mach run ./main_abs.ml
  from absolute path
