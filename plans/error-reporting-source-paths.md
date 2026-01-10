# Plan: Error Reporting with Original Source File Paths

## Problem

When there's a compilation error in a dependency, `ocamlc` reports the error with the build directory path instead of the original source file path:

```
File ".config/mach/build/__path__lib.ml/lib.ml", line 3, characters 6-12:
```

This is confusing because users don't know about the build directory structure.

## Solution

Use OCaml's `#line` directive (also known as location directive) to tell the compiler about the original source location. The syntax is:

```ocaml
# 1 "original/path/to/file.ml"
```

This directive at the top of a preprocessed file tells the OCaml compiler to report errors as if they came from the specified file starting at line 1.

## Implementation

Modify the `preprocess_source` function in `bin/main.ml` to:

1. Accept an additional parameter for the original source path
2. Output the `#line` directive as the first line of the preprocessed file
3. Ensure line numbers remain correct (since we already preserve line numbers by replacing directives with empty lines)

### Current code (bin/main.ml:65-73):

```ocaml
let preprocess_source oc ic =
  let rec loop in_header =
    match In_channel.input_line ic with
    | None -> ()
    | Some line when is_empty_line line -> output_line oc line; loop in_header
    | Some line when in_header && is_directive line -> output_line oc ""; loop true
    | Some line -> output_line oc line; loop false
  in
  loop true
```

### New code:

```ocaml
let preprocess_source ~source_path oc ic =
  fprintf oc "# 1 %S\n" source_path;
  let rec loop in_header =
    match In_channel.input_line ic with
    | None -> ()
    | Some line when is_empty_line line -> output_line oc line; loop in_header
    | Some line when in_header && is_directive line -> output_line oc ""; loop true
    | Some line -> output_line oc line; loop false
  in
  loop true
```

### Update call site in `preprocess` function (bin/main.ml:248-259):

```ocaml
let preprocess build_dir src_ml =
  let src_ml = Unix.realpath src_ml in
  let module_name = module_name_of_path src_ml in
  let build_ml = Filename.(build_dir / module_name ^ ".ml") in
  Out_channel.with_open_text build_ml (fun oc ->
    In_channel.with_open_text src_ml (fun ic ->
      preprocess_source ~source_path:src_ml oc ic));
  Option.iter (fun src_mli ->
    let build_mli = Filename.(build_dir / module_name ^ ".mli") in
    Out_channel.with_open_text build_mli (fun oc ->
      fprintf oc "# 1 %S\n" src_mli;  (* Add #line directive for .mli too *)
      let content = In_channel.with_open_text src_mli In_channel.input_all in
      output_string oc content)
  ) (mli_path_of_ml_if_exists src_ml)
```

## Line Number Considerations

The `#line` directive tells the compiler "the next line is line 1 of file X". Since we add this as the first line of the preprocessed file, we need to ensure line numbers still match.

Actually, looking more carefully: the `# 1 "file"` directive itself doesn't count as a source line - it tells the compiler that the *following* line should be treated as line 1. So this should work correctly.

## Testing

The test file `test/test_error_in_dep.t` has two test cases:
1. Type error in `.ml` dependency - should show original `lib.ml` path
2. Syntax error in `.mli` file - should show original `lib2.mli` path

After implementation, run `dune test` and `dune promote` to update expected output.

## Files to Modify

1. `bin/main.ml` - Add `~source_path` parameter to `preprocess_source` and update call site, also add `#line` directive when copying `.mli` files
2. `test/test_error_in_dep.t` - Already created, will need `dune promote` after fix
