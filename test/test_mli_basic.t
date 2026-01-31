Test basic .mli interface file support.

  $ cat << 'EOF' > lib.ml
  > let msg = "hello"
  > let secret = "hidden"
  > EOF

  $ cat << 'EOF' > lib.mli
  > val msg : string
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib"
  > let () = print_endline Lib.msg
  > EOF

  $ mach run ./main.ml
  hello

Check that .mli was copied to build dir:

  $ ls _mach/build/*__lib.ml | sort
  Mach.state
  includes.args
  lib.cmi
  lib.cmt
  lib.cmti
  lib.cmx
  lib.ml
  lib.mli
  lib.o
  mach.build
