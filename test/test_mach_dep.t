Test mach dep subcommand.

Create a simple module with no dependencies:
  $ cat << 'EOF' > foo.ml
  > let x = 1
  > EOF

  $ mach dep foo.ml -o foo.dep
  $ cat foo.dep
  ninja_dyndep_version = 1
  build foo.cmx: dyndep

Create a module that depends on another:
  $ cat << 'EOF' > bar.ml
  > let y = Foo.x + 1
  > EOF

  $ cat << 'EOF' > includes.args
  > -I=.
  > EOF

  $ mach dep bar.ml -o bar.dep --args includes.args
  $ cat bar.dep
  ninja_dyndep_version = 1
  build bar.cmx: dyndep | foo.cmx
