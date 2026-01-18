Test removing a dependency from the graph.

  $ . ../env.sh

Start with a dependency:

  $ cat << 'EOF' > lib.ml
  > let msg = "from lib"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib"
  > let () = print_endline Lib.msg
  > EOF

  $ mach run ./main.ml
  from lib

  $ sleep 1

Remove the dependency:

  $ cat << 'EOF' > main.ml
  > let () = print_endline "no more lib"
  > EOF

  $ mach run ./main.ml
  no more lib
