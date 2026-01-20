Test error when using libs without ocamlfind installed.

Create a fake ocamlfind that always fails (shadows real one in PATH):

  $ mkdir -p fake_bin
  $ cat > fake_bin/ocamlfind << 'SCRIPT'
  > #!/bin/sh
  > exit 1
  > SCRIPT
  $ chmod +x fake_bin/ocamlfind

Create a script that uses a lib:

  $ cat << 'EOF' > main.ml
  > #require "cmdliner";;
  > let () = print_endline "hello"
  > EOF

Run with fake ocamlfind first in PATH:

  $ PATH="$PWD/fake_bin:$PATH" mach run ./main.ml 2>&1
  mach: $TESTCASE_ROOT/main.ml:1: library "cmdliner" requires ocamlfind but ocamlfind is not installed
  [1]

Script without libs should work fine even without ocamlfind:

  $ cat << 'EOF' > simple.ml
  > let () = print_endline "no libs"
  > EOF

  $ PATH="$PWD/fake_bin:$PATH" mach run ./simple.ml
  no libs
