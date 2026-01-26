Test library depending on another library.

Create a base library:
  $ mkdir -p baselib
  $ cat << 'EOF' > baselib/core.ml
  > let greet name = Printf.printf "Hello, %s!\n" name
  > let version = "1.0"
  > EOF

  $ cat << 'EOF' > baselib/Machlib
  > (require)
  > EOF

Create a library that depends on the base library:
  $ mkdir -p toplib
  $ cat << 'EOF' > toplib/helper.ml
  > let say_hello name =
  >   Core.greet name;
  >   Printf.printf "Version: %s\n" Core.version
  > EOF

  $ cat << 'EOF' > toplib/Machlib
  > (require "../baselib")
  > EOF

Create a script that uses the top library:
  $ cat << 'EOF' > main.ml
  > #require "./toplib"
  > let () = Helper.say_hello "World"
  > EOF

Run the script:
  $ mach run -v ./main.ml
  mach: configuring library $TESTCASE_ROOT/baselib
  mach: configuring library $TESTCASE_ROOT/toplib
  mach: configuring $TESTCASE_ROOT/main.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)
  mach: building...
  Hello, World!
  Version: 1.0

Verify both libraries were built:
  $ test -f _mach/build/*__baselib/baselib.cmxa && echo "baselib.cmxa exists"
  baselib.cmxa exists
  $ test -f _mach/build/*__toplib/toplib.cmxa && echo "toplib.cmxa exists"
  toplib.cmxa exists

Test that changes to base library trigger rebuild of dependent library:
  $ cat << 'EOF' > baselib/core.ml
  > let greet name = Printf.printf "Hi, %s!\n" name
  > let version = "2.0"
  > EOF

  $ mach run -v ./main.ml
  mach: building...
  Hi, World!
  Version: 2.0
