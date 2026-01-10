# Plan: Fuse Require Extraction and Preprocessing

## Problem Analysis

Currently, the code parses each source file **multiple times**:

1. **`extract_requires`** (lines 58-85): Parses file, traverses AST with `Ast_iterator` to find `[%%require]` strings
2. **`preprocess_to_string`** (lines 97-109): Parses file **again**, filters requires, converts to string

Additionally, `filter_requires` (lines 89-95) only removes `[%%require]` at the top level using `List.filter`. It doesn't handle requires nested in modules or other structures.

These functions are called multiple times during execution:
- `collect_deps` → calls `extract_requires` for each file
- `resolve_deps` → calls `extract_requires` **again** for each file
- `resolve_deps` → calls `preprocess_to_string` for each file
- `run` function → calls `preprocess_to_string` **again** when writing to store (line 250)

## Solution

Create a single function that:
1. Parses the file **once**
2. Uses `Ast_mapper` to simultaneously:
   - Extract all `[%%require "..."]` directives at **any module level**
   - Remove them from the AST
3. Returns both: the list of requires AND the preprocessed source string

## Implementation Steps

### Step 1: Create New Combined Function

Replace `extract_requires`, `filter_requires`, and `preprocess_to_string` with a single function:

```ocaml
(** Parse source file once, extract requires and return preprocessed content.
    Uses Ast_mapper to handle [%%require] at any nesting level. *)
let parse_and_preprocess source_path : string list * string =
  let structure =
    In_channel.with_open_text source_path @@ fun ic ->
    let lexbuf = Lexing.from_channel ic in
    lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = source_path };
    Parse.implementation lexbuf
  in
  let requires = ref [] in
  let mapper = {
    Ast_mapper.default_mapper with
    structure = (fun self items ->
      (* Filter out require extensions at this level *)
      let filtered = List.filter_map (fun item ->
        match item.Parsetree.pstr_desc with
        | Pstr_extension (({ txt = "require"; _ }, payload), _) ->
            (* Extract the string and record it *)
            (match extract_string_from_payload payload with
             | Some s -> requires := s :: !requires
             | None -> ());
            None  (* Remove this item *)
        | _ ->
            Some (Ast_mapper.default_mapper.structure_item self item)
      ) items in
      filtered
    );
  } in
  let filtered_structure = mapper.structure mapper structure in
  (* Convert AST back to string *)
  let buf = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer buf in
  Pprintast.structure fmt filtered_structure;
  Format.pp_print_flush fmt ();
  (List.rev !requires, Buffer.contents buf)
```

### Step 2: Update `collect_deps`

Modify to use the new function and return parsed data directly. No cache needed - each file is visited exactly once during DFS:

```ocaml
type parsed_source = {
  path: string;
  requires: string list;
  preprocessed: string;
}

let collect_deps entry_path =
  let visited = Hashtbl.create 16 in
  let result = ref [] in

  let rec visit path =
    let abs_path = normalize_path path in
    match Hashtbl.find_opt visited abs_path with
    | Some InProgress ->
        failwith (Printf.sprintf "Circular dependency detected: %s" abs_path)
    | Some Done -> ()
    | None ->
        Hashtbl.add visited abs_path InProgress;
        let requires, preprocessed = parse_and_preprocess abs_path in
        visit_deps ~relative_to:abs_path requires;
        Hashtbl.replace visited abs_path Done;
        result := { path = abs_path; requires; preprocessed } :: !result
  and visit_deps ~relative_to =
    List.iter (fun dep ->
      let resolved = resolve_path ~relative_to dep in
      visit resolved
    )
  in

  let entry_path = normalize_path entry_path in
  Hashtbl.add visited entry_path InProgress;
  let requires, preprocessed = parse_and_preprocess entry_path in
  visit_deps ~relative_to:entry_path requires;
  (* Return deps in topological order, plus entry script info *)
  (List.rev !result, { path = entry_path; requires; preprocessed })
```

### Step 3: Update `resolve_deps`

Use the parsed data from `collect_deps` directly:

```ocaml
let resolve_deps ~store_dir script_path =
  let parsed_deps, entry_parsed = collect_deps script_path in
  let hash_map = Hashtbl.create 16 in
  let deps = List.map (fun source ->
    let module_name = module_name_of_path source.path in
    let module_base = String.uncapitalize_ascii module_name in
    let resolved_requires =
      List.map (fun req -> resolve_path ~relative_to:source.path req) source.requires
    in
    let dep_hashes =
      List.map (fun resolved -> Hashtbl.find hash_map resolved) resolved_requires
    in
    let hash = compute_hash ~dep_hashes ~preprocessed_content:source.preprocessed in
    Hashtbl.add hash_map source.path hash;
    let in_store = find_in_store ~store_dir ~hash ~module_name:module_base in
    { source; hash; module_name = module_base; in_store; resolved_requires }
  ) parsed_deps in
  (deps, entry_parsed)  (* Also return entry script's parsed data *)
```

### Step 4: Update `dep_info` Type

Embed `parsed_source` instead of duplicating fields:

```ocaml
type dep_info = {
  source: parsed_source;
  hash: string;
  module_name: string;
  in_store: bool;
  resolved_requires: string list;  (* absolute paths, resolved from source.requires *)
}
```

Access preprocessed content via `dep.source.preprocessed`, path via `dep.source.path`, etc.

### Step 5: Update `run` Function

Use the embedded `source.preprocessed` field instead of calling `preprocess_to_string`:

```ocaml
(* In run function, line 250 changes from: *)
write_file source_ml (preprocess_to_string dep.path);
(* To: *)
write_file source_ml dep.source.preprocessed;
```

Entry script is already returned from `resolve_deps` as `entry_parsed`, so use `entry_parsed.preprocessed` for the entry script.

### Step 6: Delete Old Functions

Remove:
- `extract_requires` (lines 58-85)
- `filter_requires` (lines 89-95)
- `preprocess_to_string` (lines 97-109)

Keep:
- `extract_string_from_payload` (used by new function)

## File Changes Summary

| Location | Change |
|----------|--------|
| Lines 58-109 | Replace `extract_requires`, `filter_requires`, `preprocess_to_string` with `parsed_source` type and `parse_and_preprocess` |
| Lines 123-129 | Change `dep_info` to embed `source: parsed_source` |
| Lines 135-160 | Update `collect_deps` to return `parsed_source list * parsed_source` |
| Lines 162-180 | Update `resolve_deps` to use parsed data directly |
| Lines 249-251 | Use `dep.source.preprocessed` instead of `preprocess_to_string` |
| Lines 259-263 | Use `entry_parsed.preprocessed` for entry script |

## Benefits

1. **Performance**: Each file parsed exactly once
2. **Consistency**: Same AST used for extraction and preprocessing
3. **Better handling**: `Ast_mapper` handles `[%%require]` at any nesting level (inside module expressions, etc.)
4. **Simpler code**: Three functions become one

## Testing

Existing cram tests should continue to pass. Consider adding a test with nested module that contains `[%%require]` to verify the `Ast_mapper` correctly handles nested cases.

## Risks

- The `Ast_mapper` approach changes the structure traversal. Need to ensure all require locations are handled correctly.
- Using `filter_map` on structure items is non-standard for `Ast_mapper`. May need to adjust the mapper pattern.

## Alternative Approach

If `Ast_mapper` complexity is a concern, could keep simpler approach:
1. Single parse per file
2. Two passes over AST (one to extract, one to filter)
3. Still better than parsing twice

But the `Ast_mapper` approach is cleaner and handles nesting.
