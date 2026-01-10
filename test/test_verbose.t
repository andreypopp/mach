
  $ source ../env.sh

  $ cat << 'EOF' > hello.ml
  > print_endline "hello"
  > EOF

Without --verbose, no command logging:

  $ mach run ./hello.ml 2>&1
  hello

With --verbose, make command is logged to stderr (build may be cached):

  $ mach run --verbose ./hello.ml >/dev/null 2>/dev/null
