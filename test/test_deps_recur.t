  $ . ../env.sh

  $ cat << 'EOF' > lib_b.ml
  > let hello () = print_endline "Hello from lib_b"
  > EOF

  $ cat << 'EOF' > lib_a.ml
  > #require "./lib_b.ml"
  > let hello () =
  >   Lib_b.hello ();
  >   print_endline "Hello from lib_a"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib_a.ml"
  > let () = Lib_a.hello ()
  > EOF

  $ mach run ./main.ml
  Hello from lib_b
  Hello from lib_a
