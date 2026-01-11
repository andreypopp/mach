Test mach pp command (preprocessor for merlin)

  $ . ../env.sh

Create a test file with shebang and #require directives:

  $ cat > script.ml << 'EOF'
  > #!/usr/bin/env mach
  > #require "./lib.ml"
  > 
  > let () = print_endline "hello"
  > EOF

Run mach pp - should replace shebang and #require with empty lines:

  $ mach pp script.ml
  # 1 "script.ml"
  
  
  
  let () = print_endline "hello"

Test with file that has no directives:

  $ cat > plain.ml << 'EOF'
  > let x = 42
  > let y = x + 1
  > EOF

  $ mach pp plain.ml
  # 1 "plain.ml"
  let x = 42
  let y = x + 1
