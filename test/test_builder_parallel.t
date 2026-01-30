Test parallel build execution

  $ B=$PWD/_build && mkdir -p $B

Test that independent targets build in parallel:

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt"))
  >   (deps ())
  >   (commands ("sleep 0.2" "echo a > $B/a.txt")))
  > (Rule
  >   (targets ("$B/b.txt"))
  >   (deps ())
  >   (commands ("sleep 0.2" "echo b > $B/b.txt")))
  > (Rule
  >   (targets ("$B/final.txt"))
  >   (deps ("$B/a.txt" "$B/b.txt"))
  >   (commands ("cat $B/a.txt $B/b.txt > $B/final.txt")))
  > EOF

With -j2, independent targets a.txt and b.txt should build in parallel:

  $ mach builder -j2 --build-file="$B/build.sexp" "$B/final.txt"

  $ cat "$B/final.txt" | sort
  a
  b

Test that -j1 works (sequential execution):

  $ rm -f $B/a.txt $B/b.txt $B/final.txt

  $ mach builder -j1 --build-file="$B/build.sexp" "$B/final.txt"

  $ cat "$B/final.txt" | sort
  a
  b

Test fail-fast: first error should stop the build:

  $ rm -f $B/*.txt

  $ cat > $B/build_fail.sexp << EOF
  > (Rule
  >   (targets ("$B/fail.txt"))
  >   (deps ())
  >   (commands ("exit 1")))
  > (Rule
  >   (targets ("$B/ok.txt"))
  >   (deps ())
  >   (commands ("echo ok > $B/ok.txt")))
  > (Rule
  >   (targets ("$B/result.txt"))
  >   (deps ("$B/fail.txt" "$B/ok.txt"))
  >   (commands ("echo done > $B/result.txt")))
  > EOF

  $ mach builder -j2 --build-file="$B/build_fail.sexp" "$B/result.txt"
  mach: error: build error (exit 1)
  [1]

Test that dependency order is respected:

  $ rm -f $B/*.txt

  $ cat > $B/build_deps.sexp << EOF
  > (Rule
  >   (targets ("$B/step1.txt"))
  >   (deps ())
  >   (commands ("echo step1 > $B/step1.txt")))
  > (Rule
  >   (targets ("$B/step2.txt"))
  >   (deps ("$B/step1.txt"))
  >   (commands ("cat $B/step1.txt > $B/step2.txt" "echo step2 >> $B/step2.txt")))
  > (Rule
  >   (targets ("$B/step3.txt"))
  >   (deps ("$B/step2.txt"))
  >   (commands ("cat $B/step2.txt > $B/step3.txt" "echo step3 >> $B/step3.txt")))
  > EOF

  $ mach builder -j4 --build-file="$B/build_deps.sexp" "$B/step3.txt"

  $ cat "$B/step3.txt"
  step1
  step2
  step3
