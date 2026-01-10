Test removing a transitive dependency.

  $ source ../env.sh

  $ cat << 'EOF' > lib_b.ml
  > let extra = " + lib_b"
  > EOF

  $ cat << 'EOF' > lib_a.ml
  > #require "./lib_b.ml"
  > let msg = "lib_a" ^ Lib_b.extra
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib_a.ml"
  > let () = print_endline Lib_a.msg
  > EOF

  $ mach run ./main.ml
  lib_a + lib_b

  $ sleep 1

Remove the transitive dependency:

  $ cat << 'EOF' > lib_a.ml
  > let msg = "lib_a alone"
  > EOF

  $ mach run ./main.ml
  lib_a alone
