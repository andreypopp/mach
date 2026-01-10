# Plan: Refactoring require directive syntax

## Overview

Change the syntax for require directives from OCaml extension syntax (`[%%require "mod.ml"]`) to a simpler directive-based syntax (`#require "mod.ml"`) that doesn't require the full OCaml parser.

## Current Implementation

The current implementation in `bin/main.ml` uses:
1. `read_source` - reads file content, strips shebang line if present, returns content and start line
2. `parse_source` - calls OCaml's `Parse.implementation` to get AST
3. `extract_requires` - walks AST to find `[%%require "..."]` extensions
4. `preprocess_source` - uses `Ast_mapper` to filter out require nodes, then `Pprintast` to emit clean source

## New Syntax

```ocaml
#!/usr/bin/env mach run
#require "mod.ml"
#require "./lib.ml" ;;

(* OCaml code starts here *)
let () = print_endline "Hello"
```

### Rules

1. Directives must appear at the top of the file (after optional shebang)
2. Empty lines are allowed between directives
3. `;;` after a directive is allowed but ignored (for toplevel compatibility)
4. Once OCaml code is encountered, directive parsing stops
5. Any `#require` appearing after OCaml code is ignored (treated as regular code)

## Implementation Steps

### Step 1: Define directive parsing function

Add a new function `parse_directives : in_channel -> string list` that:
- Takes an input channel and reads line by line
- Returns list of require paths extracted from `#require "..."` lines

The function should:
- Handle shebang line (`#!...`) - skip it
- Handle `#require "..."` directives - extract the path
- Handle empty lines - skip them
- Handle `;;` after directives - ignore them
- Stop parsing when OCaml code is encountered (ignore any `#require` after that)

### Step 2: Implement line-by-line parsing logic

Create helper function to parse each line:
- Detect shebang: line starts with `#!`
- Detect require: line matches `#require "..."` with optional trailing `;;` and whitespace
- Detect empty/whitespace line
- Detect OCaml code: anything else

State machine:
1. `AtStart` - can see shebang, require, empty, or transition to code
2. `InDirectives` - can see require, empty, or transition to code
3. `InCode` - done parsing, return accumulated requires

### Step 3: Update `read_source`

Modify to use new directive parsing:
- Instead of just stripping shebang, parse all directives
- Return requires as well as content

Or better: rename/replace with `parse_directives` that returns structured data.

### Step 4: Update `extract_requires`

Simplify to just call the new directive parser:
- No more AST walking needed
- Just extract from parsed directive structure

### Step 5: Update `preprocess_source`

Simplify significantly:
- No longer need AST parsing and mapping
- Replace shebang and `#require` directive lines with empty lines (to preserve line numbers for compiler error messages)
- Output the rest of the file unchanged

Key insight: with the new syntax, `#require` is NOT valid OCaml syntax, so we need to strip those lines. But we don't need the OCaml parser - just replace directive lines with empty lines to maintain line number correspondence.

### Step 6: Update tests

Update all test files to use new syntax:
- `test_simple.t` - change `[%%require "./lib.ml"]` to `#require "./lib.ml"`
- `test_deps_recur.t` - update both lib_a.ml and main.ml
- `test_dup_require.t` - update to new syntax
- Other tests as needed

### Step 7: Add new tests for edge cases

Add tests for:
- `#require` with trailing `;;`
- Multiple empty lines between directives

## Detailed Code Changes

### Helper functions

```ocaml
let is_empty_line line =
  String.for_all (function ' ' | '\t' -> true | _ -> false) line
```

### New parsing function

```ocaml
(* Returns list of require paths from directives at the top of the file.
   Stops parsing when OCaml code is encountered. *)
let parse_directives ic : string list =
  let rec loop acc =
    match In_channel.input_line ic with
    | None -> List.rev acc
    | Some line ->
      if is_empty_line line then
        loop acc
      else if String.length line > 0 && line.[0] = '#' then
        match extract_require_path line with
        | Some path -> loop (path :: acc)
        | None -> loop acc  (* shebang or other # line *)
      else
        List.rev acc  (* hit code, we're done *)
  in
  loop []
```

### Extract require path helper

```ocaml
(* Parse: #require "path" or #require "path" ;;
   Assumes line starts with '#' *)
let extract_require_path line =
  let len = String.length line in
  (* Check for "require " after # *)
  if len < 9 then None
  else if String.sub line 1 7 <> "require" then None
  else
    (* Find opening quote *)
    let rec find_quote i =
      if i >= len then None
      else match line.[i] with
        | ' ' | '\t' -> find_quote (i + 1)
        | '"' -> Some i
        | _ -> None
    in
    match find_quote 8 with
    | None -> None
    | Some quote_start ->
      (* Find closing quote *)
      let rec find_end i =
        if i >= len then None
        else if line.[i] = '"' then Some i
        else find_end (i + 1)
      in
      match find_end (quote_start + 1) with
      | None -> None
      | Some quote_end ->
        Some (String.sub line (quote_start + 1) (quote_end - quote_start - 1))
```

### Updated extract_requires

```ocaml
let extract_requires source_path =
  In_channel.with_open_text source_path parse_directives
```

### Updated preprocess_source

```ocaml
(* Process line by line from ic to oc, replacing #-lines with empty lines at top *)
let preprocess_source ic oc =
  let rec in_directives () =
    match In_channel.input_line ic with
    | None -> ()
    | Some line ->
      if is_empty_line line then begin
        output_line oc line;
        in_directives ()
      end else if String.length line > 0 && line.[0] = '#' then begin
        output_line oc "";
        in_directives ()
      end else begin
        output_line oc line;
        in_code ()
      end
  and in_code () =
    match In_channel.input_line ic with
    | None -> ()
    | Some line ->
      output_line oc line;
      in_code ()
  in
  in_directives ()
```

Usage in `preprocess` command:
```ocaml
let preprocess build_dir source_path =
  let source_path = Unix.realpath source_path in
  let module_name = module_name_of_path source_path in
  let source_ml = Filename.(build_dir / module_name ^ ".ml") in
  In_channel.with_open_text source_path (fun ic ->
    Out_channel.with_open_text source_ml (fun oc ->
      preprocess_source ic oc))
```

## Impact Analysis

### Files to modify:
- `bin/main.ml` - main implementation changes, remove all OCaml parser/AST code
- `bin/dune` - remove `compiler-libs.common` dependency

### Code to remove from main.ml:
- `extract_string_from_payload` - no longer needed (AST payload extraction)
- `read_source` - replaced by simpler logic in `parse_directives` and `preprocess_source`
- `parse_source` - no longer needed (was calling `Parse.implementation`)
- All `Parsetree`, `Ast_mapper`, `Pprintast`, `Parse` usage

### Dune change:
```diff
 (libraries cmdliner compiler-libs.common unix)
+(libraries cmdliner unix)
```

### Tests to update:
- `test/test_simple.t`
- `test/test_deps_recur.t`
- `test/test_dup_require.t`

### Tests to add:
- New test for `;;` suffix support

## Risks and Considerations

1. **Backward compatibility**: This is a breaking change. Existing scripts using `[%%require "..."]` will break. The task description doesn't mention backward compatibility support, so we'll do a clean switch.

2. **Error messages**: We need good error messages for invalid syntax (e.g., malformed `#require` lines).

3. **Comments**: What if there are OCaml comments before the first require? We should treat comments as OCaml code (i.e., directives must come before any comments too). This simplifies parsing and is consistent with the "directives at top" rule.

4. **Whitespace in paths**: The path inside quotes can contain spaces. Our parsing handles this since we look for the quote boundaries.

5. **Escape sequences in paths**: For simplicity, we won't support escape sequences in paths (e.g., `\"` or `\\`). This seems reasonable for file paths.

6. **`#require` in code**: Since we stop parsing at the first line of code and ignore `#require` thereafter, it's safe to have `#require` in comments or string literals within the code section - they'll be treated as regular OCaml code.
