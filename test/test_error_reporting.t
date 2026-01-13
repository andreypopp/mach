Error reporting tests - user errors should be reported nicely to stderr.

  $ . ../env.sh

Test error when script file doesn't exist (cmdliner validates before our code runs):

  $ mach run ./nonexistent.ml
  Usage: mach run [--help] [--verbose] [OPTION]… SCRIPT [ARGS]…
  mach: SCRIPT argument: no ./nonexistent.ml file
  [124]

  $ mach build ./nonexistent.ml
  Usage: mach build [--help] [--verbose] [--watch] [OPTION]… SCRIPT
  mach: SCRIPT argument: no ./nonexistent.ml file
  [124]

  $ mach configure ./nonexistent.ml
  Usage: mach configure [--help] [OPTION]… SOURCE
  mach: SOURCE argument: no ./nonexistent.ml file
  [124]

Test error when a required dependency doesn't exist:

  $ cat << 'EOF' > script.ml
  > #require "./missing_dep.ml"
  > let () = print_endline "hello"
  > EOF

  $ mach run ./script.ml
  mach: $TESTCASE_ROOT/script.ml:1: $TESTCASE_ROOT/./missing_dep.ml: No such file or directory
  [1]

Test error when build fails:

  $ cat << 'EOF' > bad_script.ml
  > let () = this_is_not_valid
  > EOF

  $ mach run ./bad_script.ml 2>&1 | grep -E "(Unbound|mach:)"
  Error: Unbound value this_is_not_valid
  mach: build failed
