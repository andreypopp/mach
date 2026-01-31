Test cycle detection with multi-target rules.

Ensure that cycles involving multi-target rules are correctly detected.

  $ B=$PWD/_build && mkdir -p $B

Test 1: Direct cycle - multi-target rule depends on one of its own targets
==========================================================================

This is a bit artificial but tests the cycle detection.

  $ cat > $B/direct_cycle.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt" "$B/b.txt"))
  >   (deps ("$B/a.txt"))
  >   (commands ("echo a > $B/a.txt" "echo b > $B/b.txt")))
  > EOF

  $ mach builder --build-file="$B/direct_cycle.sexp" "$B/a.txt"
  mach: error: dependency cycle detected: $TESTCASE_ROOT/_build/a.txt
  [1]

Test 2: Indirect cycle through another rule
===========================================

  $ cat > $B/indirect_cycle.sexp << EOF
  > (Rule
  >   (targets ("$B/gen.h" "$B/gen.c"))
  >   (deps ("$B/intermediate.txt"))
  >   (commands ("echo h > $B/gen.h" "echo c > $B/gen.c")))
  > (Rule
  >   (targets ("$B/intermediate.txt"))
  >   (deps ("$B/gen.h"))
  >   (commands ("echo intermediate > $B/intermediate.txt")))
  > EOF

  $ mach builder --build-file="$B/indirect_cycle.sexp" "$B/gen.c"
  mach: error: dependency cycle detected: $TESTCASE_ROOT/_build/intermediate.txt
  [1]

Test 3: Cycle involving multiple multi-target rules
====================================================

  $ cat > $B/multi_cycle.sexp << EOF
  > (Rule
  >   (targets ("$B/a1.txt" "$B/a2.txt"))
  >   (deps ("$B/b1.txt"))
  >   (commands ("echo a1 > $B/a1.txt" "echo a2 > $B/a2.txt")))
  > (Rule
  >   (targets ("$B/b1.txt" "$B/b2.txt"))
  >   (deps ("$B/a2.txt"))
  >   (commands ("echo b1 > $B/b1.txt" "echo b2 > $B/b2.txt")))
  > EOF

  $ mach builder --build-file="$B/multi_cycle.sexp" "$B/a1.txt"
  mach: error: dependency cycle detected: $TESTCASE_ROOT/_build/b1.txt
  [1]
