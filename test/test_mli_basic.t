Test basic .mli interface file support.

  $ . ../env.sh

  $ cat << 'EOF' > lib.ml
  > let msg = "hello"
  > let secret = "hidden"
  > EOF

  $ cat << 'EOF' > lib.mli
  > val msg : string
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = print_endline Lib.msg
  > EOF

  $ mach run ./main.ml
  hello

Check that .mli was copied to build dir:

  $ ls _mach/build/*__lib.ml/*.mli | xargs basename
  lib.mli
