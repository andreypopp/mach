Isolate mach config to a test dir:
  $ . ../env.sh

Create a script that uses cmdliner:
  $ cat << 'EOF' > main.ml
  > #require "cmdliner";;
  > 
  > let () =
  >   let open Cmdliner in
  >   let name = Arg.(value & opt string "World" & info ["n"; "name"] ~doc:"Name to greet") in
  >   let greet name = Printf.printf "Hello, %s!\n" name in
  >   let cmd = Cmd.v (Cmd.info "greet") Term.(const greet $ name) in
  >   exit (Cmd.eval cmd)
  > EOF

Test basic run:
  $ mach run ./main.ml
  Hello, World!

Test with argument:
  $ mach run ./main.ml -- -n Claude
  Hello, Claude!

Verify lib_includes.args was generated:
  $ test -f _mach/build/*__main.ml/lib_includes.args && echo "exists"
  exists

Verify lib_objects.args was generated:
  $ test -f _mach/build/*__main.ml/lib_objects.args && echo "exists"
  exists

Inspect lib_includes.args (should contain -I paths for cmdliner):
  $ grep -c cmdliner _mach/build/*__main.ml/lib_includes.args
  1

Test adding a lib triggers reconfiguration:

Start with a script without libs:
  $ rm -rf _mach
  $ cat << 'EOF' > simple.ml
  > let () = print_endline "no libs"
  > EOF

  $ mach run -vv ./simple.ml 2>&1
  mach:configure: no previous state found, creating one...
  mach: configuring...
  mach: building...
  no libs

Verify no lib args files exist:
  $ test -f _mach/build/*__simple.ml/lib_includes.args && echo "exists" || echo "not exists"
  not exists
  $ test -f _mach/build/*__simple.ml/lib_objects.args && echo "exists" || echo "not exists"
  not exists

Add a lib - SHOULD reconfigure:
  $ sleep 1
  $ cat << 'EOF' > simple.ml
  > #require "cmdliner";;
  > let () = print_endline "with cmdliner"
  > EOF

  $ mach run -vv ./simple.ml 2>&1
  mach:state: requires/libs changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: building...
  with cmdliner

Verify lib args files now exist:
  $ test -f _mach/build/*__simple.ml/lib_includes.args && echo "exists" || echo "not exists"
  exists
  $ test -f _mach/build/*__simple.ml/lib_objects.args && echo "exists" || echo "not exists"
  exists

Test removing a lib triggers reconfiguration:

Remove the lib - SHOULD reconfigure:
  $ sleep 1
  $ cat << 'EOF' > simple.ml
  > let () = print_endline "libs removed"
  > EOF

  $ mach run -vv ./simple.ml 2>&1
  mach:state: requires/libs changed, need reconfigure
  mach:configure: need reconfigure
  mach: configuring...
  mach: building...
  libs removed

Verify lib args files no longer exist:
  $ test -f _mach/build/*__simple.ml/lib_includes.args && echo "exists" || echo "not exists"
  not exists
  $ test -f _mach/build/*__simple.ml/lib_objects.args && echo "exists" || echo "not exists"
  not exists
