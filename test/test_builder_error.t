Test mach builder error handling when a command fails

  $ B=$PWD/_build && mkdir -p $B

Test that a failing command produces a proper error message:

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/fail.txt"))
  >   (deps ())
  >   (commands ("exit 1")))
  > EOF

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/fail.txt"
  mach: building $TESTCASE_ROOT/_build/fail.txt
  mach: error: build error (exit 1)
  [1]

Test that a command with non-zero exit code shows the exit code:

  $ cat > $B/build2.sexp << EOF
  > (Rule
  >   (targets ("$B/fail2.txt"))
  >   (deps ())
  >   (commands ("exit 42")))
  > EOF

  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/fail2.txt"
  mach: building $TESTCASE_ROOT/_build/fail2.txt
  mach: error: build error (exit 42)
  [1]

Test that the error shows the actual failing command:

  $ cat > $B/build3.sexp << EOF
  > (Rule
  >   (targets ("$B/fail3.txt"))
  >   (deps ())
  >   (commands ("echo start" "false" "echo end")))
  > EOF

  $ mach builder -vvv --build-file="$B/build3.sexp" "$B/fail3.txt"
  mach: building $TESTCASE_ROOT/_build/fail3.txt
  start
  mach: error: build error (exit 1)
  [1]

Test dependency cycle detection (A depends on B, B depends on A):

  $ cat > $B/build_cycle.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt"))
  >   (deps ("$B/b.txt"))
  >   (commands ("cat $B/b.txt > $B/a.txt")))
  > (Rule
  >   (targets ("$B/b.txt"))
  >   (deps ("$B/a.txt"))
  >   (commands ("cat $B/a.txt > $B/b.txt")))
  > EOF

  $ mach builder -v --build-file="$B/build_cycle.sexp" "$B/a.txt"
  mach: error: dependency cycle detected: $TESTCASE_ROOT/_build/a.txt
  [1]

Test longer dependency cycle (A -> B -> C -> A):

  $ cat > $B/build_cycle2.sexp << EOF
  > (Rule
  >   (targets ("$B/x.txt"))
  >   (deps ("$B/y.txt"))
  >   (commands ("echo x")))
  > (Rule
  >   (targets ("$B/y.txt"))
  >   (deps ("$B/z.txt"))
  >   (commands ("echo y")))
  > (Rule
  >   (targets ("$B/z.txt"))
  >   (deps ("$B/x.txt"))
  >   (commands ("echo z")))
  > EOF

  $ mach builder -v --build-file="$B/build_cycle2.sexp" "$B/x.txt"
  mach: error: dependency cycle detected: $TESTCASE_ROOT/_build/x.txt
  [1]

Test dyndep referencing unknown target:

  $ cat > $B/build_dyndep_unknown.sexp << EOF
  > (Rule
  >   (targets ("$B/main.txt"))
  >   (deps ("$B/dyndep.txt"))
  >   (commands ("echo done > $B/main.txt")))
  > (Rule_dyndep
  >   (target "$B/dyndep.txt")
  >   (deps ())
  >   (commands ("echo '((target \"$B/nonexistent.txt\") (deps (\"$B/foo.txt\")))' > $B/dyndep.txt")))
  > EOF

  $ mach builder -vvv --build-file="$B/build_dyndep_unknown.sexp" "$B/main.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep.txt
  mach: error: dyndep references unknown target: $TESTCASE_ROOT/_build/nonexistent.txt
  [1]

Test dyndep can add deps to an unscheduled rule (rule has no deps, so deps_pending=0,
but it was never scheduled because it's not in the dependency chain):

  $ cat > $B/build_dyndep_unscheduled.sexp << EOF
  > (Rule
  >   (targets ("$B/main2.txt"))
  >   (deps ("$B/dyndep2.txt"))
  >   (commands ("echo done > $B/main2.txt")))
  > (Rule_dyndep
  >   (target "$B/dyndep2.txt")
  >   (deps ())
  >   (commands ("echo '((target \"$B/other.txt\") (deps (\"$B/extra.txt\")))' > $B/dyndep2.txt")))
  > (Rule
  >   (targets ("$B/other.txt"))
  >   (deps ())
  >   (commands ("echo other > $B/other.txt")))
  > (Rule
  >   (targets ("$B/extra.txt"))
  >   (deps ())
  >   (commands ("echo extra > $B/extra.txt")))
  > EOF

This should work - other.txt was never scheduled, even though it has deps_pending=0:

  $ mach builder -vvv --build-file="$B/build_dyndep_unscheduled.sexp" "$B/main2.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep2.txt
  mach: building $TESTCASE_ROOT/_build/extra.txt
  mach: building $TESTCASE_ROOT/_build/main2.txt
  mach: building $TESTCASE_ROOT/_build/other.txt

Test dyndep referencing target that is actually scheduled (in the dependency chain):

  $ cat > $B/build_dyndep_scheduled.sexp << EOF
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/dyndep3.txt" "$B/target.txt"))
  >   (commands ("echo done > $B/final.txt")))
  > (Rule_dyndep
  >   (target "$B/dyndep3.txt")
  >   (deps ())
  >   (commands ("echo '((target \"$B/target.txt\") (deps (\"$B/extra2.txt\")))' > $B/dyndep3.txt")))
  > (Rule
  >   (targets ("$B/target.txt"))
  >   (deps ())
  >   (commands ("echo target > $B/target.txt")))
  > (Rule
  >   (targets ("$B/extra2.txt"))
  >   (deps ())
  >   (commands ("echo extra > $B/extra2.txt")))
  > EOF

This should error - target.txt is scheduled because final.txt depends on it directly:

  $ mach builder -vvv --build-file="$B/build_dyndep_scheduled.sexp" "$B/final.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep3.txt
  mach: building $TESTCASE_ROOT/_build/target.txt
  mach: error: dyndep references target that is already scheduled/built: $TESTCASE_ROOT/_build/target.txt
  [1]
