  $ cat << 'EOF' > myscript.ml
  > #!/usr/bin/env mach
  > print_endline "Hello from shebang script!"
  > EOF

  $ mach run ./myscript.ml
  Hello from shebang script!

  $ ls _mach/build/*myscript.ml/ | sort
  Mach.build
  Mach.state
  a.out
  includes.args
  myscript.cmi
  myscript.cmt
  myscript.cmx
  myscript.ml
  myscript.o
  objs.args
