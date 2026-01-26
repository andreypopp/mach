Test library depending on a module.

Create a standalone module:
  $ cat << 'EOF' > utils.ml
  > let double x = x * 2
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

Create a library that depends on the module:
  $ mkdir -p mylib
  $ cat << 'EOF' > mylib/helper.ml
  > let quadruple x = Utils.double (Utils.double x)
  > let say_hello name = Utils.greet name
  > EOF

  $ cat << 'EOF' > mylib/Machlib
  > (require "../utils.ml")
  > EOF

Create a script that uses the library:
  $ cat << 'EOF' > main.ml
  > #require "./mylib"
  > let () =
  >   Printf.printf "quadruple 3 = %d\n" (Helper.quadruple 3);
  >   Helper.say_hello "World"
  > EOF

Run the script:
  $ mach run ./main.ml
  quadruple 3 = 12
  Hello, World!

Verify the library was built:
  $ test -f _mach/build/*__mylib/mylib.cmxa && echo "mylib.cmxa exists"
  mylib.cmxa exists

Test that changes to the module trigger rebuild:
  $ cat << 'EOF' > utils.ml
  > let double x = x * 2
  > let greet name = Printf.printf "Hi, %s!\n" name
  > EOF

  $ mach run ./main.ml
  quadruple 3 = 12
  Hi, World!
