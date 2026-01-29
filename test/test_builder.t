Test mach builder with a simple target with no dependencies

  $ B=$PWD/_build && mkdir -p $B

Create a build spec for a single target with no deps:

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/hello.txt"))
  >   (deps ())
  >   (commands ("echo hello > $B/hello.txt")))
  > EOF

Run the builder:

  $ mach builder -v --build-file="$B/build.sexp" "$B/hello.txt"
  mach: building $TESTCASE_ROOT/_build/hello.txt

Check the target was created:

  $ cat "$B/hello.txt"
  hello

Test build with dependencies (A depends on B):

  $ cat > $B/build2.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt"))
  >   (deps ("$B/b.txt"))
  >   (commands ("cat $B/b.txt >> $B/a.txt" "echo 'from a' >> $B/a.txt")))
  > (Rule
  >   (targets ("$B/b.txt"))
  >   (deps ())
  >   (commands ("echo 'from b' > $B/b.txt")))
  > EOF

  $ mach builder -v --build-file="$B/build2.sexp" "$B/a.txt"
  mach: building $TESTCASE_ROOT/_build/b.txt
  mach: building $TESTCASE_ROOT/_build/a.txt

  $ cat "$B/a.txt"
  from b
  from a

Test build with diamond dependencies (A depends on B and C, both depend on D):

  $ cat > $B/build3.sexp << EOF
  > (Rule
  >   (targets ("$B/a2.txt"))
  >   (deps ("$B/b2.txt" "$B/c2.txt"))
  >   (commands ("cat $B/b2.txt $B/c2.txt > $B/a2.txt")))
  > (Rule
  >   (targets ("$B/b2.txt"))
  >   (deps ("$B/d2.txt"))
  >   (commands ("echo 'b:' > $B/b2.txt" "cat $B/d2.txt >> $B/b2.txt")))
  > (Rule
  >   (targets ("$B/c2.txt"))
  >   (deps ("$B/d2.txt"))
  >   (commands ("echo 'c:' > $B/c2.txt" "cat $B/d2.txt >> $B/c2.txt")))
  > (Rule
  >   (targets ("$B/d2.txt"))
  >   (deps ())
  >   (commands ("echo 'shared' > $B/d2.txt")))
  > EOF

  $ mach builder -v --build-file="$B/build3.sexp" "$B/a2.txt"
  mach: building $TESTCASE_ROOT/_build/d2.txt
  mach: building $TESTCASE_ROOT/_build/c2.txt
  mach: building $TESTCASE_ROOT/_build/b2.txt
  mach: building $TESTCASE_ROOT/_build/a2.txt

D is built once, then B and C, then A:

  $ cat "$B/a2.txt"
  b:
  shared
  c:
  shared
