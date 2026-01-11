Test adding a new dependency to the graph.

  $ . ../env.sh

Start with no dependencies:

  $ cat << 'EOF' > main.ml
  > let () = print_endline "no deps"
  > EOF

  $ mach run ./main.ml
  no deps

  $ sleep 1

Create a new library and add it as dependency:

  $ cat << 'EOF' > lib.ml
  > let msg = "with lib"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = print_endline Lib.msg
  > EOF

  $ mach run ./main.ml
  with lib
