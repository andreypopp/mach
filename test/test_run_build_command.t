Test run-build-command subcommand:

Test basic command execution:

  $ mach run-build-command -- echo hello
  >>>hello

Test command that writes to stderr:

  $ mach run-build-command -- sh -c 'echo error >&2'
  >>>error

Test exit code propagation:

  $ mach run-build-command -- false
  [1]

  $ mach run-build-command -- sh -c 'exit 42'
  [42]

Test multiple lines:

  $ mach run-build-command -- sh -c 'echo line1; echo line2; echo line3'
  >>>line1
  >>>line2
  >>>line3

Test mixed stdout and stderr:

  $ mach run-build-command -- sh -c 'echo out1; echo err1 >&2; echo out2; echo err2 >&2'
  >>>out1
  >>>err1
  >>>out2
  >>>err2

Test empty output:

  $ mach run-build-command -- true

Test command with no output but exit code:

  $ mach run-build-command -- sh -c 'exit 5'
  [5]

Test arguments with spaces:

  $ mach run-build-command -- echo "hello world"
  >>>hello world
