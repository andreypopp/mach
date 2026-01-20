Test replacing a dependency with another.

  $ cat << 'EOF' > old_lib.ml
  > let name = "old"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./old_lib"
  > let () = print_endline ("using " ^ Old_lib.name)
  > EOF

  $ mach run ./main.ml
  using old

  $ sleep 1

Replace with a new dependency:

  $ cat << 'EOF' > new_lib.ml
  > let name = "new"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./new_lib"
  > let () = print_endline ("using " ^ New_lib.name)
  > EOF

  $ mach run ./main.ml
  using new
