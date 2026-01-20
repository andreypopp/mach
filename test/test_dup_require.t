  $ cat << 'EOF' > lib.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

  $ cat << 'EOF' > a.ml
  > #require "./lib"
  > let greet = Lib.greet
  > EOF

  $ cat << 'EOF' > b.ml
  > #require "./lib"
  > let greet = Lib.greet
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./a"
  > #require "./b"
  > let () = A.greet "World"
  > let () = B.greet "World"
  > EOF

  $ mach run ./main.ml
  Hello, World!
  Hello, World!
