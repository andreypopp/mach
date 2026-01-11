Test mach-lsp ocaml-merlin subcommand
  $ . ../env.sh

Setup test files:

  $ cat > lib.ml << 'EOF'
  > let x = 42
  > EOF

  $ cat > main.ml << 'EOF'
  > #require "./lib.ml"
  > let () = print_int Lib.x
  > EOF

Test File command returns directives (starts with FLG for preprocessor):

  $ printf '(4:File7:main.ml)' | mach-lsp ocaml-merlin 2>/dev/null | head -c 5
  ((3:F

Test that output contains FLG, S, B, and CMT directives:

  $ printf '(4:File7:main.ml)' | mach-lsp ocaml-merlin 2>/dev/null | grep -o '3:FLG\|1:S\|1:B\|3:CMT' | sort -u
  1:B
  1:S
  3:CMT
  3:FLG

Test that we get S and B for all dependencies (main.ml and lib.ml = 2 each):

  $ printf '(4:File7:main.ml)' | mach-lsp ocaml-merlin 2>/dev/null | grep -o '1:S' | wc -l | tr -d ' '
  3
  $ printf '(4:File7:main.ml)' | mach-lsp ocaml-merlin 2>/dev/null | grep -o '1:B' | wc -l | tr -d ' '
  2

Test Halt command exits cleanly:

  $ printf '4:Halt' | mach-lsp ocaml-merlin
