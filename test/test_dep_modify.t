Test modifying a dependency.

  $ . ../env.sh

  $ cat << 'EOF' > lib.ml
  > let version = "v1"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib"
  > let () = print_endline Lib.version
  > EOF

  $ mach run ./main.ml
  v1

  $ sleep 1

Modify the dependency:

  $ cat << 'EOF' > lib.ml
  > let version = "v2"
  > EOF

  $ mach run ./main.ml
  v2
