Test adding a transitive dependency.

  $ cat << 'EOF' > lib_a.ml
  > let msg = "lib_a only"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib_a"
  > let () = print_endline Lib_a.msg
  > EOF

  $ mach run ./main.ml
  lib_a only

  $ sleep 1

Add a transitive dependency:

  $ cat << 'EOF' > lib_b.ml
  > let extra = " + lib_b"
  > EOF

  $ cat << 'EOF' > lib_a.ml
  > #require "./lib_b"
  > let msg = "lib_a" ^ Lib_b.extra
  > EOF

  $ mach run ./main.ml
  lib_a + lib_b
