Test building a library with mach build (without running).

Create a library with two modules:
  $ mkdir -p mylib
  $ cat << 'EOF' > mylib/foo.ml
  > let greet name = Printf.printf "Hello from Foo, %s!\n" name
  > EOF

  $ cat << 'EOF' > mylib/bar.ml
  > let message = "Hello from Bar!"
  > EOF

  $ cat << 'EOF' > mylib/Machlib
  > (require)
  > EOF

Create a script that uses the library:
  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () =
  >   Foo.greet "World";
  >   print_endline Bar.message
  > EOF

Build without running:
  $ mach build ./main.ml

Check the executable was created:
  $ test -f _mach/build/*__main.ml/a.out && echo "exists"
  exists

Check the library artifacts were created:
  $ ls _mach/build/*__mylib | grep -E '\.(cmxa|cmi|cmx)$' | sort
  bar.cmi
  bar.cmx
  foo.cmi
  foo.cmx
  mylib.cmxa

Run the executable manually:
  $ _mach/build/*__main.ml/a.out
  Hello from Foo, World!
  Hello from Bar!

Test building a library directly (not through a script):
  $ rm -rf _mach
  $ mach build ./mylib/
  $ test -f _mach/build/*__mylib/mylib.cmxa && echo "cmxa exists"
  cmxa exists

Test that running a library gives an appropriate error:
  $ mach run ./mylib/ 2>&1
  mach: cannot run a library, use 'mach build' instead
  [1]
