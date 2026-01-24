Test basic library support with Machlib file.

Create a library with two modules:
  $ mkdir -p mylib
  $ cat << 'EOF' > mylib/foo.ml
  > let greet name = Printf.printf "Hello from Foo, %s!\n" name
  > EOF

  $ cat << 'EOF' > mylib/bar.ml
  > let message = "Hello from Bar!"
  > let greet () = print_endline message
  > EOF

  $ cat << 'EOF' > mylib/Machlib
  > (require)
  > EOF

Create a script that uses the library:
  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () =
  >   Foo.greet "World";
  >   Bar.greet ()
  > EOF

Run the script:
  $ mach run ./main.ml
  Hello from Foo, World!
  Hello from Bar!

Inspect the library build dir:
  $ ls _mach/build/*__mylib | grep -E '\.(cmxa|cmi|cmx|ml|dep)$' | sort
  bar.cmi
  bar.cmx
  bar.dep
  bar.ml
  foo.cmi
  foo.cmx
  foo.dep
  foo.ml
  mylib.cmxa

Test library with inter-module dependencies:
  $ cat << 'EOF' > mylib/baz.ml
  > let combined () =
  >   Foo.greet "Baz";
  >   Bar.greet ()
  > EOF

  $ cat << 'EOF' > main2.ml
  > #require "./mylib"
  > let () = Baz.combined ()
  > EOF

  $ mach run ./main2.ml
  Hello from Foo, Baz!
  Hello from Bar!
