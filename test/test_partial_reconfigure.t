Test partial reconfiguration - only affected modules are reconfigured.

  $ . ../env.sh

Create a script with two dependencies:

  $ cat << 'EOF' > lib_a.ml
  > let msg = "lib_a"
  > EOF

  $ cat << 'EOF' > lib_b.ml
  > let msg = "lib_b"
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./lib_a"
  > #require "./lib_b"
  > let () = Printf.printf "%s %s\n" Lib_a.msg Lib_b.msg
  > EOF

First build:

  $ mach run ./main.ml
  lib_a lib_b

Change only lib_a's requires (add new require):

  $ cat << 'EOF' > lib_c.ml
  > let extra = "!"
  > EOF

  $ sleep 1
  $ cat << 'EOF' > lib_a.ml
  > #require "./lib_c"
  > let msg = "lib_a" ^ Lib_c.extra
  > EOF

Verify reconfiguration happens and build succeeds:

  $ mach run -vv ./main.ml 2>&1 | grep -E "(reconfigure|configuring)"
  mach:state: requires/libs changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/lib_c.ml
  mach: configuring $TESTCASE_ROOT/lib_a.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)

  $ mach run ./main.ml
  lib_a! lib_b

Change lib_b (without changing requires) - should rebuild but not reconfigure:

  $ sleep 1
  $ cat << 'EOF' > lib_b.ml
  > let msg = "lib_b_updated"
  > EOF

  $ mach run -vv ./main.ml 2>&1 | grep -E "(reconfigure|configuring)" || echo "no reconfigure"
  no reconfigure

  $ mach run ./main.ml
  lib_a! lib_b_updated

Add .mli file to lib_b - should trigger partial reconfiguration for lib_b only:

  $ sleep 1
  $ cat << 'EOF' > lib_b.mli
  > val msg : string
  > EOF

  $ mach run -vv ./main.ml 2>&1 | grep -E "(reconfigure|configuring)"
  mach:state: .mli added/removed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/lib_b.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)

  $ mach run ./main.ml
  lib_a! lib_b_updated

Remove .mli file from lib_b - should trigger partial reconfiguration for lib_b only:

  $ sleep 1
  $ rm lib_b.mli

  $ mach run -vv ./main.ml 2>&1 | grep -E "(reconfigure|configuring)"
  mach:state: .mli added/removed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: configuring $TESTCASE_ROOT/lib_b.ml
  mach: configuring $TESTCASE_ROOT/main.ml (root)

  $ mach run ./main.ml
  lib_a! lib_b_updated
