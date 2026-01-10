# Plan: Add test for shebang line support

## Task Description

Add a cram test to verify that OCaml scripts with shebang lines (`#!/usr/bin/env mach`) work correctly with mach.

## Background

**Correction**: OCaml's `Parse.implementation` does NOT natively handle shebang lines. Testing revealed a `Syntaxerr.Error` when parsing a file with `#!` at the beginning.

We need to:
1. Implement shebang line handling in `parse_and_preprocess`
2. Add a cram test to verify this behavior

## Implementation Steps

1. **Modify `parse_and_preprocess` in bin/main.ml**:
   - Read file content as a string first
   - Check if content starts with `#!`
   - If so, find the first newline and skip the shebang line
   - Create lexbuf from the (potentially modified) content
   - Adjust the lexer position to account for the skipped line

2. **Create test file**: `test/test_shebang.t`

## Code Changes

### bin/main.ml - parse_and_preprocess function

Replace channel-based parsing with string-based parsing that handles shebangs:

```ocaml
let parse_and_preprocess source_path =
  let content = In_channel.with_open_text source_path In_channel.input_all in
  let content, start_line =
    if String.length content >= 2 && content.[0] = '#' && content.[1] = '!' then
      match String.index_opt content '\n' with
      | Some pos -> (String.sub content (pos + 1) (String.length content - pos - 1), 2)
      | None -> ("", 2)  (* file is just a shebang line *)
    else
      (content, 1)
  in
  let lexbuf = Lexing.from_string content in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = source_path; pos_lnum = start_line };
  let structure = Parse.implementation lexbuf in
  (* ... rest of function unchanged ... *)
```

## Test Design

```
  $ cat << 'EOF' > script.ml
  > #!/usr/bin/env mach
  > print_endline "Hello from shebang script!"
  > EOF

  $ mach run --store ./store ./script.ml
  Hello from shebang script!
```

## Files to Modify

- **Modify**: `bin/main.ml` - add shebang handling in `parse_and_preprocess`
- **Create**: `test/test_shebang.t` - new cram test file

## Verification

Run `dune test` to ensure the new test passes.

## Summary (completed)

Implemented shebang line support by modifying `parse_and_preprocess` to:
1. Read file content as a string
2. Skip the first line if it starts with `#!`
3. Adjust lexer position to report correct line numbers in error messages

Added cram test `test/test_shebang.t` that verifies shebang scripts work.
