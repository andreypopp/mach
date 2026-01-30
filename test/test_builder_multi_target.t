Test mach builder with multiple targets per rule

  $ B=$PWD/_build && mkdir -p $B

Test a rule that produces multiple targets from a single command:

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/header.h" "$B/source.c"))
  >   (deps ())
  >   (commands ("echo '// header' > $B/header.h" "echo '// source' > $B/source.c")))
  > EOF

Run the builder requesting one of the targets:

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/header.h"
  mach: building $TESTCASE_ROOT/_build/header.h
  mach: building $TESTCASE_ROOT/_build/source.c

Both targets should be created:

  $ cat "$B/header.h"
  // header

  $ cat "$B/source.c"
  // source

Test rule with multiple targets where other rules depend on different targets:

  $ rm -rf $B && mkdir -p $B

  $ cat > $B/build2.sexp << EOF
  > (Rule
  >   (targets ("$B/gen.h" "$B/gen.c"))
  >   (deps ())
  >   (commands ("echo '#define VALUE 42' > $B/gen.h" "echo 'int x = VALUE;' > $B/gen.c")))
  > (Rule
  >   (targets ("$B/uses_header.txt"))
  >   (deps ("$B/gen.h"))
  >   (commands ("cat $B/gen.h > $B/uses_header.txt")))
  > (Rule
  >   (targets ("$B/uses_source.txt"))
  >   (deps ("$B/gen.c"))
  >   (commands ("cat $B/gen.c > $B/uses_source.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/uses_header.txt" "$B/uses_source.txt"))
  >   (commands ("cat $B/uses_header.txt $B/uses_source.txt > $B/final.txt")))
  > EOF

Build final.txt which depends on both outputs of the multi-target rule.
The multi-target rule should only be built once:

  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/gen.h
  mach: building $TESTCASE_ROOT/_build/gen.c
  mach: building $TESTCASE_ROOT/_build/uses_header.txt
  mach: building $TESTCASE_ROOT/_build/uses_source.txt
  mach: building $TESTCASE_ROOT/_build/final.txt

  $ cat "$B/final.txt"
  #define VALUE 42
  int x = VALUE;

Test incremental rebuild - touch gen.h, only dependents of gen.h should rebuild:

  $ sleep 0.1
  $ touch "$B/gen.h"
  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/uses_header.txt
  mach: building $TESTCASE_ROOT/_build/final.txt
