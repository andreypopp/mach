Test mach builder with multi-target rules that have dependencies.

This tests a bug where scheduling different targets of the same multi-target rule
causes the rule's dependencies to be iterated multiple times, leading to incorrect
deps_pending counting.

The bug is triggered when:
1. A multi-target rule [A, B] depends on a target produced by another rule (not a source file)
2. Two different rules depend on A and B respectively
3. Both A and B are needed transitively

  $ B=$PWD/_build && mkdir -p $B

Setup:
- intermediate.txt is produced
- Multi-target rule produces [gen.h, gen.c] and depends on intermediate.txt
- final.txt depends on gen.h and gen.c

The key is that gen.h and gen.c come from the same rule that depends on
intermediate.txt (a rule target), and they are dependencies of different rules
that are both needed for final.txt. This causes the multi-target rule's deps
to be iterated twice, adding it to rev_deps twice for intermediate.txt.

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/intermediate.txt"))
  >   (deps ())
  >   (commands ("echo ok > $B/intermediate.txt")))
  > (Rule
  >   (targets ("$B/gen.h" "$B/gen.c"))
  >   (deps ("$B/intermediate.txt"))
  >   (commands ("cat $B/intermediate.txt > $B/gen.h" "cat $B/intermediate.txt > $B/gen.c")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/gen.h" "$B/gen.c"))
  >   (commands ("cat $B/gen.h $B/gen.c > $B/final.txt")))
  > EOF

Build final.txt. This should work correctly - the multi-target rule should only
be processed once even though both gen.h and gen.c are needed:

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/intermediate.txt
  mach: building $TESTCASE_ROOT/_build/gen.h
  mach: building $TESTCASE_ROOT/_build/gen.c
  mach: building $TESTCASE_ROOT/_build/final.txt

Verify the output:

  $ cat "$B/final.txt"
  ok
  ok
