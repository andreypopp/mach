Isolate mach config to a test dir:

  $ source ../env.sh

Prepare source files with a type error in the dependency:
  $ cat << 'EOF' > lib.ml
  > let greet name =
  >   Printf.printf "Hello, %s!\n" name;
  >   1 + "oops"  (* type error *)
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib.ml"
  > let () = Lib.greet "World"
  > EOF

Test error reporting (should show lib.ml path, not build dir path):
  $ mach run ./main.ml 2>&1
  File "$TESTCASE_ROOT/lib.ml", line 3, characters 6-12:
  Error: This constant has type string but an expression was expected of type
           int
  mach: build failed
  [1]

Now test error in .mli file:
  $ rm -rf .config

  $ cat << 'EOF' > lib2.mli
  > val greet : string -> unit
  > val broken : int ->
  > EOF

  $ cat << 'EOF' > lib2.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > let broken x = x
  > EOF

  $ cat << 'EOF' > main2.ml
  > #require "./lib2.ml"
  > let () = Lib2.greet "World"
  > EOF

Test error reporting for .mli (should show lib2.mli path, not build dir path):
  $ mach run ./main2.ml
  File "$TESTCASE_ROOT/lib2.mli", line 3, characters 0-0:
  Error: Syntax error
  mach: build failed
  [1]
