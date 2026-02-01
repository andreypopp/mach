Test mach builder incremental builds (change tracking)

  $ B=$PWD/_build && mkdir -p $B

Create a simple build spec:

  $ cat > $B/build.sexp << EOF
  > (Rule
  >   (targets ("$B/output.txt"))
  >   (deps ("$B/source.txt"))
  >   (commands ("cat $B/source.txt > $B/output.txt" "echo 'processed' >> $B/output.txt")))
  > EOF

Create source file:

  $ echo "initial content" > $B/source.txt

First build should run:

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/output.txt"
  mach: building $TESTCASE_ROOT/_build/output.txt

  $ cat "$B/output.txt"
  initial content
  processed

Second build without changes should skip:

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/output.txt"

(no output - target was up-to-date)

Touch the source file to trigger rebuild:

  $ sleep 1
  $ touch $B/source.txt

Now build should run again:

  $ mach builder -vvv --build-file="$B/build.sexp" "$B/output.txt"
  mach: building $TESTCASE_ROOT/_build/output.txt

Test with dependency chain (A depends on B depends on C):

  $ cat > $B/build2.sexp << EOF
  > (Rule
  >   (targets ("$B/a.txt"))
  >   (deps ("$B/b.txt"))
  >   (commands ("cat $B/b.txt > $B/a.txt" "echo 'a' >> $B/a.txt")))
  > (Rule
  >   (targets ("$B/b.txt"))
  >   (deps ("$B/c.txt"))
  >   (commands ("cat $B/c.txt > $B/b.txt" "echo 'b' >> $B/b.txt")))
  > (Rule
  >   (targets ("$B/c.txt"))
  >   (deps ())
  >   (commands ("echo 'c' > $B/c.txt")))
  > EOF

First build - all targets built:

  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/a.txt"
  mach: building $TESTCASE_ROOT/_build/c.txt
  mach: building $TESTCASE_ROOT/_build/b.txt
  mach: building $TESTCASE_ROOT/_build/a.txt

  $ cat "$B/a.txt"
  c
  b
  a

Second build - nothing rebuilt:

  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/a.txt"

Touch intermediate target b.txt - should rebuild only a:

  $ sleep 1
  $ touch $B/b.txt
  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/a.txt"
  mach: building $TESTCASE_ROOT/_build/a.txt

Touch source c.txt - should rebuild b and a:

  $ sleep 1
  $ touch $B/c.txt
  $ mach builder -vvv --build-file="$B/build2.sexp" "$B/a.txt"
  mach: building $TESTCASE_ROOT/_build/b.txt
  mach: building $TESTCASE_ROOT/_build/a.txt

Test with dyndeps:

  $ cat > $B/build3.sexp << EOF
  > (Rule
  >   (targets ("$B/main.txt"))
  >   (deps ("$B/dyndep.txt"))
  >   (commands ("cat $B/extra.txt > $B/main.txt" "echo 'main' >> $B/main.txt")))
  > (Rule_dyndep
  >   (targets ("$B/dyndep.txt"))
  >   (deps ())
  >   (commands ("echo '((target \"$B/main.txt\") (deps (\"$B/extra.txt\")))' > $B/dyndep.txt")))
  > (Rule
  >   (targets ("$B/extra.txt"))
  >   (deps ())
  >   (commands ("echo 'extra' > $B/extra.txt")))
  > EOF

First build:

  $ mach builder -vvv --build-file="$B/build3.sexp" "$B/main.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep.txt
  mach: building $TESTCASE_ROOT/_build/extra.txt
  mach: building $TESTCASE_ROOT/_build/main.txt

  $ cat "$B/main.txt"
  extra
  main

Second build - nothing rebuilt:

  $ mach builder -vvv --build-file="$B/build3.sexp" "$B/main.txt"

Touch the dyndep-discovered dep - should rebuild main:

  $ sleep 1
  $ touch $B/extra.txt
  $ mach builder -vvv --build-file="$B/build3.sexp" "$B/main.txt"
  mach: building $TESTCASE_ROOT/_build/main.txt

Test dyndep re-evaluation (dyndep changes to point to different deps):

Create two possible dependencies and a config file that controls which one is used:

  $ echo "content from dep1" > $B/dep1.txt
  $ echo "content from dep2" > $B/dep2.txt
  $ echo "dep1" > $B/config.txt

Create a helper script that generates the dyndep file based on config:

  $ cat > $B/gen_dyndep.sh << 'SCRIPT'
  > #!/bin/sh
  > CONFIG_FILE="$1"
  > TARGET="$2"
  > OUTPUT="$3"
  > DEP=$(cat "$CONFIG_FILE")
  > DEPDIR=$(dirname "$CONFIG_FILE")
  > echo "((target \"$TARGET\") (deps (\"$DEPDIR/$DEP.txt\")))" > "$OUTPUT"
  > SCRIPT
  $ chmod +x $B/gen_dyndep.sh

Build spec where dyndep reads config to decide which dep to declare:

  $ cat > $B/build4.sexp << EOF
  > (Rule
  >   (targets ("$B/result.txt"))
  >   (deps ("$B/dyndep4.txt"))
  >   (commands ("cat $B/dep1.txt $B/dep2.txt 2>/dev/null > $B/result.txt || true" "echo done >> $B/result.txt")))
  > (Rule_dyndep
  >   (targets ("$B/dyndep4.txt"))
  >   (deps ("$B/config.txt"))
  >   (commands ("$B/gen_dyndep.sh $B/config.txt $B/result.txt $B/dyndep4.txt")))
  > EOF

First build - config says dep1, so dyndep should declare dep1:

  $ mach builder -vvv --build-file="$B/build4.sexp" "$B/result.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep4.txt
  mach: building $TESTCASE_ROOT/_build/result.txt

  $ cat "$B/dyndep4.txt"
  ((target "$TESTCASE_ROOT/_build/result.txt") (deps ("$TESTCASE_ROOT/_build/dep1.txt")))

Second build - nothing changed, should skip:

  $ mach builder -vvv --build-file="$B/build4.sexp" "$B/result.txt"

Now change config to point to dep2:

  $ sleep 1
  $ echo "dep2" > $B/config.txt

Rebuild - dyndep should be rebuilt (config changed), then result rebuilt with new dep:

  $ mach builder -vvv --build-file="$B/build4.sexp" "$B/result.txt"
  mach: building $TESTCASE_ROOT/_build/dyndep4.txt
  mach: building $TESTCASE_ROOT/_build/result.txt

Verify dyndep now points to dep2:

  $ cat "$B/dyndep4.txt"
  ((target "$TESTCASE_ROOT/_build/result.txt") (deps ("$TESTCASE_ROOT/_build/dep2.txt")))

Touch dep2 (the new dynamic dep) - should trigger rebuild:

  $ sleep 1
  $ touch $B/dep2.txt
  $ mach builder -vvv --build-file="$B/build4.sexp" "$B/result.txt"
  mach: building $TESTCASE_ROOT/_build/result.txt

Touch dep1 (the old dynamic dep, no longer referenced) - should NOT trigger rebuild:

  $ sleep 1
  $ touch $B/dep1.txt
  $ mach builder -vvv --build-file="$B/build4.sexp" "$B/result.txt"
