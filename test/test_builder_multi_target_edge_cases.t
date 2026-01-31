Test edge cases for multi-target rules in mach builder

  $ B=$PWD/_build && mkdir -p $B

Test 1: Three or more targets from one rule
==========================================

A rule produces 3 targets [A, B, C], and different rules depend on each.
This ensures the fix works beyond just 2 targets.

  $ cat > $B/three_targets.sexp << EOF
  > (Rule
  >   (targets ("$B/gen.a" "$B/gen.b" "$B/gen.c"))
  >   (deps ())
  >   (commands ("echo a > $B/gen.a" "echo b > $B/gen.b" "echo c > $B/gen.c")))
  > (Rule
  >   (targets ("$B/use_a.txt"))
  >   (deps ("$B/gen.a"))
  >   (commands ("cat $B/gen.a > $B/use_a.txt")))
  > (Rule
  >   (targets ("$B/use_b.txt"))
  >   (deps ("$B/gen.b"))
  >   (commands ("cat $B/gen.b > $B/use_b.txt")))
  > (Rule
  >   (targets ("$B/use_c.txt"))
  >   (deps ("$B/gen.c"))
  >   (commands ("cat $B/gen.c > $B/use_c.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/use_a.txt" "$B/use_b.txt" "$B/use_c.txt"))
  >   (commands ("cat $B/use_a.txt $B/use_b.txt $B/use_c.txt > $B/final.txt")))
  > EOF

  $ mach builder -vvv --build-file="$B/three_targets.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/gen.a
  mach: building $TESTCASE_ROOT/_build/gen.b
  mach: building $TESTCASE_ROOT/_build/gen.c
  mach: building $TESTCASE_ROOT/_build/use_a.txt
  mach: building $TESTCASE_ROOT/_build/use_b.txt
  mach: building $TESTCASE_ROOT/_build/use_c.txt
  mach: building $TESTCASE_ROOT/_build/final.txt

  $ cat "$B/final.txt"
  a
  b
  c

Test 2: Chain of multi-target rules
===================================

Multi-target rule A produces [X, Y], multi-target rule B depends on X and
produces [P, Q], and the final rule depends on Y and Q.

  $ rm -rf $B && mkdir -p $B

  $ cat > $B/chain.sexp << EOF
  > (Rule
  >   (targets ("$B/x.txt" "$B/y.txt"))
  >   (deps ())
  >   (commands ("echo x > $B/x.txt" "echo y > $B/y.txt")))
  > (Rule
  >   (targets ("$B/p.txt" "$B/q.txt"))
  >   (deps ("$B/x.txt"))
  >   (commands ("cat $B/x.txt > $B/p.txt; echo p >> $B/p.txt" "cat $B/x.txt > $B/q.txt; echo q >> $B/q.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/y.txt" "$B/q.txt"))
  >   (commands ("cat $B/y.txt $B/q.txt > $B/final.txt")))
  > EOF

  $ mach builder -vvv --build-file="$B/chain.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/x.txt
  mach: building $TESTCASE_ROOT/_build/y.txt
  mach: building $TESTCASE_ROOT/_build/p.txt
  mach: building $TESTCASE_ROOT/_build/q.txt
  mach: building $TESTCASE_ROOT/_build/final.txt

  $ cat "$B/final.txt"
  y
  x
  q

Test 3: Parallel builds with multi-target rules
===============================================

Same as test 1 but with parallelism enabled.

  $ rm -rf $B && mkdir -p $B

  $ cat > $B/parallel.sexp << EOF
  > (Rule
  >   (targets ("$B/gen.h" "$B/gen.c"))
  >   (deps ())
  >   (commands ("echo header > $B/gen.h" "echo source > $B/gen.c")))
  > (Rule
  >   (targets ("$B/uses_h.txt"))
  >   (deps ("$B/gen.h"))
  >   (commands ("cat $B/gen.h > $B/uses_h.txt")))
  > (Rule
  >   (targets ("$B/uses_c.txt"))
  >   (deps ("$B/gen.c"))
  >   (commands ("cat $B/gen.c > $B/uses_c.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/uses_h.txt" "$B/uses_c.txt"))
  >   (commands ("cat $B/uses_h.txt $B/uses_c.txt > $B/final.txt")))
  > EOF

Run with parallelism=2:

  $ mach builder -j2 --build-file="$B/parallel.sexp" "$B/final.txt"

  $ cat "$B/final.txt"
  header
  source

Test 4: Single rule depends on multiple targets from same multi-target rule
===========================================================================

A single rule depends on ALL targets from a multi-target rule.
This is different from the deps test where the dependency goes through
intermediate rules.

  $ rm -rf $B && mkdir -p $B

  $ cat > $B/direct_multi_dep.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt" "$B/b.txt" "$B/c.txt"))
  >   (deps ())
  >   (commands ("echo a > $B/a.txt" "echo b > $B/b.txt" "echo c > $B/c.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/a.txt" "$B/b.txt" "$B/c.txt"))
  >   (commands ("cat $B/a.txt $B/b.txt $B/c.txt > $B/final.txt")))
  > EOF

  $ mach builder -vvv --build-file="$B/direct_multi_dep.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/a.txt
  mach: building $TESTCASE_ROOT/_build/b.txt
  mach: building $TESTCASE_ROOT/_build/c.txt
  mach: building $TESTCASE_ROOT/_build/final.txt

  $ cat "$B/final.txt"
  a
  b
  c
