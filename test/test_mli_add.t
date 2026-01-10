Test adding .mli to existing module.

  $ source ../env.sh

Start without .mli:

  $ cat << 'EOF' > lib.ml
  > let msg = "from lib"
  > let internal = "internal"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = print_endline Lib.msg
  > let () = print_endline Lib.internal
  > EOF

  $ mach run ./main.ml
  from lib
  internal

  $ sleep 1

Now add .mli that hides internal:

  $ cat << 'EOF' > lib.mli
  > val msg : string
  > EOF

Trying to access internal should now fail:

  $ mach run ./main.ml 2>&1 | grep -E "(Error:|Unbound)"
  Error: Unbound value Lib.internal
