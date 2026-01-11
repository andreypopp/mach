  $ . ../env.sh

Prepare source files:
  $ cat << 'EOF' > hello.ml
  > print_endline "hello"
  > EOF

Build without running:
  $ mach build ./hello.ml

Check the executable was created:
  $ test -f mach/build/*__hello.ml/a.out && echo "exists"
  exists

Run the executable manually:
  $ mach/build/*__hello.ml/a.out
  hello
