# Plan: Separate Require Extraction and Preprocessing

## Problem Statement

Currently, `parse_and_preprocess` does two things at once:
1. Extracts `[%%require "..."]` directives to build the dependency graph
2. Preprocesses the source by removing require directives and re-emitting the AST

This function is called twice:
- During `configure` step (via `Mach_state.collect`) - to extract require directives
- During `preprocess` subcommand (via `preprocess`) - to generate the preprocessed `.ml` file and `includes.args`

This is inefficient because we parse and preprocess the entire file twice.

## Proposed Solution

Separate these into two distinct operations:

### 1. Extract-only function (`extract_requires`)

A new lightweight function that:
- Parses the source file (handling shebang)
- Extracts `[%%require "..."]` paths from the AST
- Returns only the list of requires (no preprocessed output)
- Does NOT traverse/transform the AST beyond extraction

```ocaml
let extract_requires source_path : string list =
  let content = In_channel.with_open_text source_path In_channel.input_all in
  let content, start_line = (* handle shebang *) in
  let lexbuf = Lexing.from_string content in
  lexbuf.lex_curr_p <- { ... };
  let structure = Parse.implementation lexbuf in
  let requires = ref [] in
  let rec collect_from_structure items =
    List.iter (fun item ->
      match item.Parsetree.pstr_desc with
      | Pstr_extension (({ txt = "require"; _ }, payload), _) ->
        (match extract_string_from_payload payload with
         | Some s -> requires := s :: !requires
         | None -> ())
      | Pstr_module { pmb_expr = { pmod_desc = Pmod_structure str; _ }; _ } ->
        collect_from_structure str
      | _ -> ()
    ) items
  in
  collect_from_structure structure;
  List.rev !requires
```

### 2. Preprocess-only function (`preprocess_source`)

A function that:
- Parses the source file (handling shebang)
- Uses `Ast_mapper` to filter out `[%%require]` nodes
- Re-emits the AST via `Pprintast`
- Returns only the preprocessed source string (no requires extraction)

```ocaml
let preprocess_source source_path : string =
  let content = In_channel.with_open_text source_path In_channel.input_all in
  let content, start_line = (* handle shebang *) in
  let lexbuf = Lexing.from_string content in
  lexbuf.lex_curr_p <- { ... };
  let structure = Parse.implementation lexbuf in
  let mapper = {
    Ast_mapper.default_mapper with
    structure = (fun self items ->
      List.filter_map (fun item ->
        match item.Parsetree.pstr_desc with
        | Pstr_extension (({ txt = "require"; _ }, _), _) -> None
        | _ -> Some (Ast_mapper.default_mapper.structure_item self item)
      ) items
    );
  } in
  let structure = mapper.structure mapper structure in
  let buf = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer buf in
  Pprintast.structure fmt structure;
  Format.pp_print_flush fmt ();
  Buffer.contents buf
```

### 3. Update `Mach_state.collect`

Change from using `parse_and_preprocess` to using `extract_requires`:

```ocaml
let collect entry_path =
  let entry_path = Unix.realpath entry_path in
  let visited = Hashtbl.create 16 in
  let entries = ref [] in
  let rec dfs path =
    if Hashtbl.mem visited path then ()
    else begin
      Hashtbl.add visited path ();
      let requires = extract_requires path in  (* Changed: only extract requires *)
      let requires = List.map (resolve_path ~relative_to:path) requires in
      List.iter dfs requires;
      entries := { path; stat = file_stat path; requires } :: !entries
    end
  in
  dfs entry_path;
  (* ... rest unchanged *)
```

### 4. Simplify `preprocess` subcommand

The `preprocess` command now only generates the preprocessed `.ml` file:

```ocaml
let preprocess build_dir source_path =
  let source_path = Unix.realpath source_path in
  let preprocessed = preprocess_source source_path in  (* Changed: only preprocess *)
  let module_name = module_name_of_path source_path in
  (* write .ml (preprocessed) only - no includes.args *)
  let source_ml = Filename.(build_dir / module_name ^ ".ml") in
  write_file source_ml preprocessed
```

### 5. Generate `includes.args` in Makefile

Move `includes.args` generation from `mach preprocess` to a Makefile target. Since we know the resolved dependencies at configure time, we can generate `includes.args` directly in `mach.mk`:

```makefile
# In mach.mk for module foo.ml with dependencies bar.ml and baz.ml
MACH_OBJS += /path/to/build/foo.cmo

/path/to/build/foo.ml: /path/to/source/foo.ml
    mach preprocess /path/to/source/foo.ml -o /path/to/build

# New: generate includes.args via Makefile rule (one echo per line)
/path/to/build/includes.args: /path/to/build/foo.ml
    rm -f $@
    echo '-I' >> $@
    echo '/path/to/build/bar' >> $@
    echo '-I' >> $@
    echo '/path/to/build/baz' >> $@

/path/to/build/foo.cmo: /path/to/build/foo.ml /path/to/build/includes.args /path/to/build/bar.cmi /path/to/build/baz.cmi
    ocamlc -c -args /path/to/build/includes.args -o /path/to/build/foo.cmo /path/to/build/foo.ml
```

Update `Makefile` module to support multi-line recipes, and update `configure_ocaml_module`:

```ocaml
(* Add a new rule variant that accepts multiple recipe lines *)
let rule_multi buf target deps recipes =
  bprintf buf "%s:" target;
  List.iter (bprintf buf " %s") deps;
  Buffer.add_char buf '\n';
  List.iter (bprintf buf "\t%s\n") recipes;
  Buffer.add_char buf '\n'

let configure_ocaml_module buf (m : ocaml_module) =
  let ml = Filename.(m.build_dir / m.module_name ^ ".ml") in
  let args = Filename.(m.build_dir / "includes.args") in
  (* preprocess rule - only generates .ml now *)
  rule buf ml [m.source.path] (Some (sprintf "mach preprocess %s -o %s" m.source.path m.build_dir));
  (* includes.args rule - one echo per line *)
  let recipes =
    [sprintf "rm -f %s" args] @
    (if m.resolved_requires = [] then [sprintf "touch %s" args]
     else List.concat_map (fun p ->
       [sprintf "echo '-I' >> %s" args;
        sprintf "echo '%s' >> %s" (default_build_dir p) args]
     ) m.resolved_requires)
  in
  rule_multi buf args [ml] recipes
```

### 6. Remove `source` type and `parse_and_preprocess`

After the refactoring, the `source` type and `parse_and_preprocess` function become unused and can be removed.

## Implementation Steps

1. Extract common shebang handling into a helper function `read_source_content`
2. Create `extract_requires` function (extract-only, no preprocessing)
3. Create `preprocess_source` function (preprocess-only, no extraction)
4. Update `Mach_state.collect` to use `extract_requires`
5. Update `preprocess` to use `preprocess_source` (only generates .ml)
6. Update `Makefile.configure_ocaml_module` to generate `includes.args` rule
7. Remove unused `source` type and `parse_and_preprocess` function
8. Run tests to verify correctness

## Trade-offs

**Benefits:**
- Cleaner separation of concerns
- `configure` step becomes lighter (no AST transformation/re-emission)
- `preprocess` subcommand becomes simpler (only preprocessing, no dependency logic)
- `includes.args` generation is now part of the Makefile, making dependencies explicit

**Costs:**
- Still parses the file twice (once for extraction, once for preprocessing)
- Slightly more code due to separate functions

Note: Full elimination of double parsing would require caching the parsed AST or combining extraction with preprocessing in a single pass that outputs both. However, that's more complex and the current refactoring improves clarity even if parsing happens twice.

## Summary of Changes (Completed)

The refactoring was successfully implemented:

1. **Added helper functions:**
   - `read_source` - handles shebang removal, returns content and start line
   - `parse_source` - parses source file using `read_source`, returns AST

2. **Created separate functions:**
   - `extract_requires` - extracts `[%%require]` paths from AST (used during configure)
   - `preprocess_source` - filters out require nodes and re-emits AST (used during build)

3. **Updated `Mach_state.collect`** to use `extract_requires` instead of the old `parse_and_preprocess`

4. **Simplified `preprocess` subcommand** to only generate the `.ml` file (no `includes.args`)

5. **Updated `Makefile.configure_ocaml_module`** to generate `includes.args` via Makefile rules with one echo per line

6. **Removed unused code:**
   - Removed `source` type
   - Removed `parse_and_preprocess` function
   - Changed `ocaml_module.source` field to `ocaml_module.source_path`

All tests pass.
