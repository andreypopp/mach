Test error reporting in libraries (should show original paths, not build dir paths).

Create a library with a type error:
  $ mkdir -p mylib
  $ cat << 'EOF' > mylib/foo.ml
  > let greet name =
  >   Printf.printf "Hello, %s!\n" name;
  >   1 + "oops"  (* type error *)
  > EOF

  $ cat << 'EOF' > mylib/Machlib
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () = Foo.greet "World"
  > EOF

Test error reporting (should show mylib/foo.ml path, not build dir path):
  $ mach run ./main.ml 2>&1
  File "$TESTCASE_ROOT/mylib/foo.ml", line 3, characters 6-12:
  Error: This constant has type string but an expression was expected of type
           int
  mach: build failed
  [1]

Now test error in .mli file within a library:
  $ rm -rf _mach

  $ mkdir -p mylib2
  $ cat << 'EOF' > mylib2/bar.mli
  > val greet : string -> unit
  > val broken : int ->
  > EOF

  $ cat << 'EOF' > mylib2/bar.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > let broken x = x
  > EOF

  $ cat << 'EOF' > mylib2/Machlib
  > EOF

  $ cat << 'EOF' > main2.ml
  > #require "./mylib2"
  > let () = Bar.greet "World"
  > EOF

Test error reporting for .mli in library (should show mylib2/bar.mli path):
  $ mach run ./main2.ml
  File "$TESTCASE_ROOT/mylib2/bar.mli", line 3, characters 0-0:
  Error: Syntax error
  mach: build failed
  [1]
