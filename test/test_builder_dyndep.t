Test mach builder with dynamic dependencies (dyndeps)

  $ B=$PWD/_build && mkdir -p $B

Test dyndeps: A depends on dyndep D, which generates additional deps at build time.
The dyndep file specifies that target A also depends on E (discovered dynamically).

Create a build spec with a dyndep rule:

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt"))
  >   (deps ("$B/dyndep.txt"))
  >   (commands ("cat $B/e.txt >> $B/a.txt" "echo 'from a' >> $B/a.txt")))
  > (Rule_dyndep
  >   (target "$B/dyndep.txt")
  >   (deps ())
  >   (commands ("echo '((target \"$B/a.txt\") (deps (\"$B/e.txt\")))' > $B/dyndep.txt")))
  > (Rule
  >   (targets ("$B/e.txt"))
  >   (deps ())
  >   (commands ("echo 'from e' > $B/e.txt")))
  > EOF

Run the builder:

  $ mach builder -v --build-file="$B/build.sexp" "$B/a.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep.txt
  mach: building $TESTCASE_ROOT/_build/e.txt
  mach: building $TESTCASE_ROOT/_build/a.txt

The dyndep was built first, then the dynamic dep E, then A:

  $ cat "$B/a.txt"
  from e
  from a

Test dyndeps with multiple dynamic dependencies:

  $ cat > $B/build2.sexp << EOF
  > (Rule
  >   (targets ("$B/main.txt"))
  >   (deps ("$B/dyndep2.txt"))
  >   (commands ("cat $B/dep1.txt $B/dep2.txt > $B/main.txt" "echo 'from main' >> $B/main.txt")))
  > (Rule_dyndep
  >   (target "$B/dyndep2.txt")
  >   (deps ())
  >   (commands ("echo '((target \"$B/main.txt\") (deps (\"$B/dep1.txt\" \"$B/dep2.txt\")))' > $B/dyndep2.txt")))
  > (Rule
  >   (targets ("$B/dep1.txt"))
  >   (deps ())
  >   (commands ("echo 'dep1' > $B/dep1.txt")))
  > (Rule
  >   (targets ("$B/dep2.txt"))
  >   (deps ())
  >   (commands ("echo 'dep2' > $B/dep2.txt")))
  > EOF

  $ mach builder -v --build-file="$B/build2.sexp" "$B/main.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep2.txt
  mach: building $TESTCASE_ROOT/_build/dep1.txt
  mach: building $TESTCASE_ROOT/_build/dep2.txt
  mach: building $TESTCASE_ROOT/_build/main.txt

  $ cat "$B/main.txt"
  dep1
  dep2
  from main
