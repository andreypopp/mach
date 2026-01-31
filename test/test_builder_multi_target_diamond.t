Test diamond dependency pattern with multi-target rules that have dependencies.

This tests the interaction of:
1. Multi-target rules with dependencies (not just source files)
2. Diamond pattern where different rules depend on different targets
3. All converging at a final target

The scenario:
- source.txt is produced by a rule
- Multi-target rule produces [gen.h, gen.c] and depends on source.txt
- use_h depends on gen.h
- use_c depends on gen.c
- final depends on both use_h and use_c (diamond)

  $ B=$PWD/_build && mkdir -p $B

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/source.txt"))
  >   (deps ())
  >   (commands ("echo 'base' > $B/source.txt")))
  > (Rule
  >   (targets ("$B/gen.h" "$B/gen.c"))
  >   (deps ("$B/source.txt"))
  >   (commands ("cat $B/source.txt > $B/gen.h; echo '.h' >> $B/gen.h" "cat $B/source.txt > $B/gen.c; echo '.c' >> $B/gen.c")))
  > (Rule
  >   (targets ("$B/use_h.txt"))
  >   (deps ("$B/gen.h"))
  >   (commands ("cat $B/gen.h > $B/use_h.txt")))
  > (Rule
  >   (targets ("$B/use_c.txt"))
  >   (deps ("$B/gen.c"))
  >   (commands ("cat $B/gen.c > $B/use_c.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/use_h.txt" "$B/use_c.txt"))
  >   (commands ("cat $B/use_h.txt $B/use_c.txt > $B/final.txt")))
  > EOF

Build the diamond. The multi-target rule should only be visited once,
and deps_pending should be correctly tracked:

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/source.txt
  mach: building $TESTCASE_ROOT/_build/gen.h
  mach: building $TESTCASE_ROOT/_build/gen.c
  mach: building $TESTCASE_ROOT/_build/use_h.txt
  mach: building $TESTCASE_ROOT/_build/use_c.txt
  mach: building $TESTCASE_ROOT/_build/final.txt

  $ cat "$B/final.txt"
  base
  .h
  base
  .c

Test with parallelism to ensure no race conditions:

  $ rm -rf $B && mkdir -p $B

  $ cat > $B/build_parallel.sexp << EOF
  > (Rule
  >   (targets ("$B/source.txt"))
  >   (deps ())
  >   (commands ("echo 'parallel' > $B/source.txt")))
  > (Rule
  >   (targets ("$B/gen.h" "$B/gen.c"))
  >   (deps ("$B/source.txt"))
  >   (commands ("cat $B/source.txt > $B/gen.h" "cat $B/source.txt > $B/gen.c")))
  > (Rule
  >   (targets ("$B/use_h.txt"))
  >   (deps ("$B/gen.h"))
  >   (commands ("cat $B/gen.h > $B/use_h.txt")))
  > (Rule
  >   (targets ("$B/use_c.txt"))
  >   (deps ("$B/gen.c"))
  >   (commands ("cat $B/gen.c > $B/use_c.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/use_h.txt" "$B/use_c.txt"))
  >   (commands ("cat $B/use_h.txt $B/use_c.txt > $B/final.txt")))
  > EOF

  $ mach builder -j4 --build-file="$B/build_parallel.sexp" "$B/final.txt"

  $ cat "$B/final.txt"
  parallel
  parallel

Test deeper diamond: two levels of multi-target rules
======================================================

  $ rm -rf $B && mkdir -p $B

  $ cat > $B/deep_diamond.sexp << EOF
  > (Rule
  >   (targets ("$B/root.txt"))
  >   (deps ())
  >   (commands ("echo root > $B/root.txt")))
  > (Rule
  >   (targets ("$B/level1a.txt" "$B/level1b.txt"))
  >   (deps ("$B/root.txt"))
  >   (commands ("echo 1a > $B/level1a.txt" "echo 1b > $B/level1b.txt")))
  > (Rule
  >   (targets ("$B/level2a.txt" "$B/level2b.txt"))
  >   (deps ("$B/level1a.txt"))
  >   (commands ("echo 2a > $B/level2a.txt" "echo 2b > $B/level2b.txt")))
  > (Rule
  >   (targets ("$B/level2c.txt" "$B/level2d.txt"))
  >   (deps ("$B/level1b.txt"))
  >   (commands ("echo 2c > $B/level2c.txt" "echo 2d > $B/level2d.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/level2a.txt" "$B/level2b.txt" "$B/level2c.txt" "$B/level2d.txt"))
  >   (commands ("cat $B/level2a.txt $B/level2b.txt $B/level2c.txt $B/level2d.txt > $B/final.txt")))
  > EOF

  $ mach builder -vvv --build-file="$B/deep_diamond.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/root.txt
  mach: building $TESTCASE_ROOT/_build/level1a.txt
  mach: building $TESTCASE_ROOT/_build/level1b.txt
  mach: building $TESTCASE_ROOT/_build/level2a.txt
  mach: building $TESTCASE_ROOT/_build/level2b.txt
  mach: building $TESTCASE_ROOT/_build/level2c.txt
  mach: building $TESTCASE_ROOT/_build/level2d.txt
  mach: building $TESTCASE_ROOT/_build/final.txt

  $ cat "$B/final.txt"
  2a
  2b
  2c
  2d
