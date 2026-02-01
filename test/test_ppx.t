Test basic PPX support in scripts.

Create a script that uses ppx_sexp_conv:
  $ cat << 'EOF' > main.ml
  > #require "sexplib0"
  > #ppx "ppx_sexp_conv"
  > open Sexplib0.Sexp_conv
  > type point = { x: int; y: int } [@@deriving sexp]
  > let () =
  >   let p = { x = 1; y = 2 } in
  >   print_endline (Sexplib0.Sexp.to_string_hum (sexp_of_point p))
  > EOF

Run the script:
  $ mach run ./main.ml
  ((x 1) (y 2))

Inspect the build dir - should have ppx driver:
  $ ls _mach/build/*__main.ml/_ppx | sort
  cclib.args
  driver.cmi
  driver.cmx
  driver.exe
  driver.ml
  driver.o
  includes.args
  lib_objs.args

Test error for unknown ppx package:
  $ cat << 'EOF' > bad_ppx.ml
  > #ppx "nonexistent_ppx_package"
  > let () = ()
  > EOF

  $ mach run ./bad_ppx.ml 2>&1
  mach: $TESTCASE_ROOT/bad_ppx.ml:1: ppx "nonexistent_ppx_package" not found
  [1]

Test PPX in a library:
  $ mkdir -p mylib
  $ cat << 'EOF' > mylib/types.ml
  > open Sexplib0.Sexp_conv
  > type color = Red | Green | Blue [@@deriving sexp]
  > EOF

  $ cat << 'EOF' > mylib/Machlib
  > (require "sexplib0")
  > (ppx "ppx_sexp_conv")
  > EOF

  $ cat << 'EOF' > use_lib.ml
  > #require "sexplib0"
  > #require "./mylib"
  > let () =
  >   let c = Types.Red in
  >   print_endline (Sexplib0.Sexp.to_string (Types.sexp_of_color c))
  > EOF

  $ mach run ./use_lib.ml
  Red

Inspect the library build dir - should have ppx driver:
  $ ls _mach/build/*__mylib/_ppx | sort
  cclib.args
  driver.cmi
  driver.cmx
  driver.exe
  driver.ml
  driver.o
  includes.args
  lib_objs.args

Test reconfiguration when ppx changes:
  $ rm -rf _mach
  $ cat << 'EOF' > reconfigure.ml
  > let () = print_endline "no ppx"
  > EOF

  $ mach run -vv ./reconfigure.ml 2>&1
  mach: configuring $TESTCASE_ROOT/reconfigure.ml
  mach: building...
  no ppx

Add a ppx - SHOULD reconfigure:
  $ sleep 1
  $ cat << 'EOF' > reconfigure.ml
  > #require "sexplib0"
  > #ppx "ppx_sexp_conv"
  > open Sexplib0.Sexp_conv
  > type t = int [@@deriving sexp]
  > let () = print_endline "with ppx"
  > EOF

  $ mach run -vv ./reconfigure.ml 2>&1
  mach: configuring $TESTCASE_ROOT/reconfigure.ml
  mach: building...
  with ppx

Remove ppx - SHOULD reconfigure:
  $ sleep 1
  $ cat << 'EOF' > reconfigure.ml
  > let () = print_endline "ppx removed"
  > EOF

  $ mach run -vv ./reconfigure.ml 2>&1
  mach: configuring $TESTCASE_ROOT/reconfigure.ml
  mach: building...
  ppx removed
