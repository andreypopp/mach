Test that a shared dependency is configured only once when multiple executables depend on it.

Setup:
  $ export MACH_HOME=$(mktemp -d)

Create a shared utility module:
  $ cat > utils.ml << 'EOF'
  > let greet name = Printf.printf "Hello, %s!\n" name
  > EOF

Create executable a.ml depending on utils.ml:
  $ cat > a.ml << 'EOF'
  > #!/usr/bin/env mach run
  > #require "./utils.ml"
  > let () = Utils.greet "from A"
  > EOF

Create executable b.ml depending on utils.ml:
  $ cat > b.ml << 'EOF'
  > #!/usr/bin/env mach run
  > #require "./utils.ml"
  > let () = Utils.greet "from B"
  > EOF

Build a.ml in verbose mode and check utils.ml is configured:
  $ mach build -v a.ml 2>&1 | grep "configuring"
  mach: configuring $TESTCASE_ROOT/utils.ml
  mach: configuring $TESTCASE_ROOT/a.ml
  mach: configuring $TESTCASE_ROOT/a.ml (root)

Build b.ml in verbose mode - utils.ml should NOT be configured again:
  $ mach build -v b.ml 2>&1 | grep "configuring"
  mach: configuring $TESTCASE_ROOT/b.ml
  mach: configuring $TESTCASE_ROOT/b.ml (root)

Verify both executables work:
  $ mach run a.ml
  Hello, from A!
  $ mach run b.ml
  Hello, from B!
