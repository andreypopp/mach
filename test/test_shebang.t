  $ cat << 'EOF' > myscript.ml
  > #!/usr/bin/env mach
  > print_endline "Hello from shebang script!"
  > EOF

  $ mach run ./myscript.ml
  Hello from shebang script!

  $ ls _mach/build/*myscript.ml/ | grep -v Makefile | grep -v .mk | grep -v .ninja | sort
  Mach.state
  a.out
  all_objects.args
  includes.args
  myscript.cmi
  myscript.cmt
  myscript.cmx
  myscript.ml
  myscript.o
