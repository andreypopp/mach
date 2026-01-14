Test error when requesting a non-existent ocamlfind library.

  $ . ../env.sh

Create a script that uses a non-existent lib:

  $ cat << 'EOF' > main.ml
  > #require "this-library-does-not-exist";;
  > let () = print_endline "hello"
  > EOF

  $ mach build ./main.ml 2>&1
  mach: $TESTCASE_ROOT/main.ml:1: library "this-library-does-not-exist" not found
  [1]

  $ mach build ./main.ml 2>&1
  mach: $TESTCASE_ROOT/main.ml:1: library "this-library-does-not-exist" not found
  [1]
