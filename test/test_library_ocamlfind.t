Test library depending on an ocamlfind library.

Create a library that wraps cmdliner:
  $ mkdir -p clilib
  $ cat << 'EOF' > clilib/cli.ml
  > let run_with_name f =
  >   let open Cmdliner in
  >   let name = Arg.(value & opt string "World" & info ["n"; "name"]) in
  >   let cmd = Cmd.v (Cmd.info "app") Term.(const f $ name) in
  >   exit (Cmd.eval cmd)
  > EOF

  $ cat << 'EOF' > clilib/Machlib
  > (require "cmdliner")
  > EOF

Create a script that uses the library:
  $ cat << 'EOF' > main.ml
  > #require "./clilib"
  > let () = Cli.run_with_name (Printf.printf "Hello, %s!\n")
  > EOF

Run the script:
  $ mach run ./main.ml
  Hello, World!

Run with argument:
  $ mach run ./main.ml -- -n Claude
  Hello, Claude!

Verify the library was built:
  $ test -f _mach/build/*__clilib/clilib.cmxa && echo "clilib.cmxa exists"
  clilib.cmxa exists
