Test removing .mli from existing module.

  $ . ../env.sh

Start with .mli:

  $ cat << 'EOF' > lib.ml
  > let msg = "from lib"
  > let internal = "was hidden"
  > EOF

  $ cat << 'EOF' > lib.mli
  > val msg : string
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = print_endline Lib.msg
  > EOF

  $ mach run ./main.ml
  from lib

Check .mli is in build dir:

  $ ls mach/build/*__lib.ml/*.mli | xargs basename
  lib.mli

  $ sleep 1

Now remove .mli:

  $ rm lib.mli

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = print_endline Lib.msg
  > let () = print_endline Lib.internal
  > EOF

Should work now that internal is accessible:

  $ mach run ./main.ml
  from lib
  was hidden

Check .mli was removed from build dir:

  $ test -f mach/build/*__lib.ml/lib.mli && echo "mli exists" || echo "mli removed"
  mli removed
