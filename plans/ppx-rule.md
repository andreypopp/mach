# PPX for Build Rules

## Overview

This plan describes implementing a PPX rewriter `ppx_rule` that provides a DSL for expressing build rules. The PPX transforms string templates with variable references into calls to `Mach_build.Rules.rule`.

## Syntax

### `[%rule ...]` - Build Rules

The `[%rule ...]` extension accepts one or more string literals:

```ocaml
(* Single command *)
[%rule "ocamlc -o >{exe} <{ml} -args <{args}"]

(* Multiple commands in single rule *)
[%rule
  "ocamlc -c -o >{cmo|cmi} <{ml} -args <{args}";
  "ocamlc -o >{exe} <{cmo}"]
```

### `[%cmd ...]` - Command Fragments

The `[%cmd ...]` extension creates `Mach_build.Cmd.t` values for composable command fragments:

```ocaml
let flags = [%cmd "-o >{exe}"]
(* expands to: Cmd.v ~targets:[exe] (Printf.sprintf "-o %s" exe) *)
```

Command fragments can be composed into rules using plain `{var}` syntax:

```ocaml
let flags = [%cmd "-o >{exe}"] in
[%rule "gcc {flags} <{src}"]
```

expands to:

```ocaml
let flags = Cmd.v ~targets:[exe] (Printf.sprintf "-o %s" exe) in
Mach_build.Rules.rule rules
  ~targets:(Array.of_list (List.flatten [flags.targets]))
  ~deps:(List.flatten [src :: flags.deps])
  [Printf.sprintf "gcc %s %s" flags.command src]
```

### Variable Syntax

- `>{var}` - Target variable (output file, type `string`)
- `>{var1|var2}` - Multiple target variables (outputs from single command position)
- `<{var}` - Dependency variable (input file, type `string`)
- `{var}` - Command fragment variable (type `Cmd.t`), its deps/targets are merged into the rule

### Expansion Example

```ocaml
[%rule "ocamlc -o >{exe} <{ml} -args <{args}"]
```

expands to:

```ocaml
Mach_build.Rules.rule rules
  ~targets:[|exe|]
  ~deps:[ml; args]
  [Printf.sprintf "ocamlc -o %s %s -args %s" exe ml args]
```

For multiple commands:

```ocaml
[%rule
  "ocamlc -c -o >{cmo|cmi} <{ml} -args <{args}";
  "ocamlc -o >{exe} <{cmo}"]
```

expands to:

```ocaml
Mach_build.Rules.rule rules
  ~targets:[|cmo; cmi; exe|]
  ~deps:[ml; args]
  [
    Printf.sprintf "ocamlc -c -o %s %s -args %s" cmo ml args;
    Printf.sprintf "ocamlc -o %s %s" exe cmo
  ]
```

Note: `cmo` appears as both a target (from first command) and used in second command. Since it's produced by a command within the rule, it is a target not a dependency.

## Implementation Plan

### Step 1: Create PPX Library Structure

Create a new directory `ppx_rule/` with:

```
ppx_rule/
  dune
  ppx_rule.ml
```

The `dune` file:

```dune
(library
 (name ppx_rule)
 (kind ppx_rewriter)
 (libraries ppxlib)
 (preprocess (pps ppxlib.metaquot)))
```

Using `ppxlib.metaquot` allows us to generate AST using natural OCaml syntax with quotations and anti-quotations instead of manually building AST nodes.

### Step 2: Implement the Parser for Rule Strings

Parse rule strings to extract:
1. Target variables (prefixed with `>`)
2. Dependency variables (prefixed with `<`)
3. The command template with `%s` placeholders for all variables

```ocaml
type var_kind = Target | Dep
type var = { name: string; kind: var_kind option }
type parsed_command = {
  vars: var list;         (* all variables in order of appearance *)
  template: string;       (* command with %s substitutions *)
}

val parse_command : string -> parsed_command
```

Parser logic:
1. Scan for `>{...}` patterns - these are targets
2. Scan for `<{...}` patterns - these are dependencies
3. Handle `>{var1|var2}` by splitting on `|`
4. Replace all variable references with `%s`
5. Track variable order for Printf arguments

### Step 3: Validate and Analyze Commands

**Validation:**
- Error if a variable appears as both target (`>{var}`) and dep (`<{var}`) within the same command
- Use ppxlib's location-aware error reporting for clear error messages

**Multi-command analysis:**
1. Parse each command string
2. Validate each command (no variable is both target and dep)
3. Collect all targets (variables with `>` prefix from any command)
4. Collect deps: variables with `<` prefix that are NOT targets (across all commands)
5. Order: targets in order of first appearance, deps in order of first appearance

### Step 4: Implement the PPX Extensions

```ocaml
open Ppxlib

(* [%cmd "..."] extension - produces Cmd.t *)
let cmd_extension =
  Extension.V3.declare "cmd"
    Extension.Context.expression
    Ast_pattern.(single_expr_payload (estring __))
    expand_cmd

(* [%rule "..."] extension - produces unit, calls Rules.rule *)
let rule_extension =
  Extension.V3.declare "rule"
    Extension.Context.expression
    Ast_pattern.(single_expr_payload __ |||
                 pstr (many (pstr_eval (estring __) nil)))
    expand_rule

let () =
  Driver.register_transformation
    ~rules:[
      Context_free.Rule.extension cmd_extension;
      Context_free.Rule.extension rule_extension;
    ]
    "ppx_rule"
```

The `expand_cmd` function:
1. Parse the command string
2. Generate `Cmd.v ~targets:[...] ~deps:[...] (Printf.sprintf "..." ...)`

The `expand_rule` function:
1. Accept either single string or list of strings
2. Parse each command string
3. Analyze to determine targets vs deps across all commands
4. For plain `{var}` variables, assume they may be `Cmd.t` and merge their deps/targets
5. Generate the `Mach_build.Rules.rule` call with merged deps/targets

### Step 5: Code Generation

Generate:
```ocaml
Mach_build.Rules.rule rules
  ~targets:[|target1; target2; ...|]
  ~deps:[dep1; dep2; ...]
  [cmd1; cmd2; ...]
```

Where each `cmd` is:
```ocaml
Printf.sprintf "template with %s" var1 var2 ...
```

Use `ppxlib.metaquot` for AST generation:
- `[%expr ...]` - generate expression AST from OCaml code
- `[%e ...]` - anti-quotation to embed dynamic expressions
- Use `Ast_builder.Default.evar`, `estring`, `elist`, `pexp_array` for dynamic parts

### Step 6: Integrate with mach_lib

Update `lib/dune`:

```dune
(library
 (name mach_lib)
 (wrapped false)
 (flags :standard -open Sexplib0.Sexp_conv)
 (preprocess (pps ppx_sexp_conv ppx_rule))
 (libraries unix sexplib0 parsexp ppx_rule))
```

### Step 7: Update Mach_ocaml_rules

Rewrite existing rules using the new syntax. For example:

Before:
```ocaml
Mach_build.Rules.rule rules ~targets:[|cmi; cmti|] ~deps:[mli; includes_args]
  [cmdf "ocamlc -bin-annot -c -opaque -args %s -o %s %s" includes_args cmi mli];
```

After:
```ocaml
[%rule "ocamlc -bin-annot -c -opaque -args <{includes_args} -o >{cmi|cmti} <{mli}"]
```

For composable command fragments:
```ocaml
let ppx_flag = [%cmd "--pp <{ppx_driver}"] in
[%rule "ocamlopt -c {ppx_flag} -o >{cmx} <{ml}"]
```

### Step 8: Handle Edge Cases

1. **Empty deps/targets**: Generate empty arrays/lists appropriately
2. **Variable ordering**: Maintain consistent ordering in Printf args
3. **Error reporting**: Use ppxlib's location-aware error reporting for malformed strings
4. **Escaping**: Handle `%` in command strings (escape as `%%`)
5. **Validation errors**: Error if same variable is both target and dep in a command

### Step 9: Add Tests

Create test cases in `test/test_ppx_rule.t`:

```
Test basic rule expansion
  $ cat > test.ml << 'EOF'
  > let rules = Mach_build.Rules.create ()
  > let exe = "/path/to/exe"
  > let ml = "/path/to/src.ml"
  > let () = [%rule "ocamlc -o >{exe} <{ml}"]
  > EOF
  $ ocamlfind ocamlc -package ppx_rule -dsource test.ml 2>&1 | grep -A5 "let ()"
```

## Implementation Details

### Parsing Algorithm

```ocaml
let parse_command str =
  let buf = Buffer.create (String.length str) in
  let vars = ref [] in
  let i = ref 0 in
  while !i < String.length str do
    match str.[!i] with
    | '>' when !i + 1 < String.length str && str.[!i+1] = '{' ->
        (* Parse target variable *)
        let j = String.index_from str (!i+2) '}' in
        let names = String.sub str (!i+2) (j - !i - 2) in
        (* Handle multiple targets: var1|var2 *)
        String.split_on_char '|' names |> List.iter (fun name ->
          vars := { name; kind = Some Target } :: !vars;
          Buffer.add_string buf "%s"
        );
        i := j + 1
    | '<' when !i + 1 < String.length str && str.[!i+1] = '{' ->
        (* Parse dependency variable *)
        let j = String.index_from str (!i+2) '}' in
        let name = String.sub str (!i+2) (j - !i - 2) in
        vars := { name; kind = Some Dep } :: !vars;
        Buffer.add_string buf "%s";
        i := j + 1
    | '{' ->
        (* Parse plain variable (not tracked as target or dep) *)
        let j = String.index_from str (!i+1) '}' in
        let name = String.sub str (!i+1) (j - !i - 1) in
        vars := { name; kind = None } :: !vars;
        Buffer.add_string buf "%s";
        i := j + 1
    | '%' ->
        Buffer.add_string buf "%%";
        incr i
    | c ->
        Buffer.add_char buf c;
        incr i
  done;
  { vars = List.rev !vars; template = Buffer.contents buf }
```

### Multi-Command Target/Dep Analysis

```ocaml
(* Validate that no variable is both target and dep in same command *)
let validate_command ~loc cmd =
  let targets = Hashtbl.create 8 in
  let deps = Hashtbl.create 8 in
  List.iter (fun var ->
    match var.kind with
    | Some Target -> Hashtbl.replace targets var.name ()
    | Some Dep -> Hashtbl.replace deps var.name ()
    | None -> ()
  ) cmd.vars;
  Hashtbl.iter (fun name () ->
    if Hashtbl.mem deps name then
      Location.raise_errorf ~loc
        "Variable '%s' cannot be both target and dependency" name
  ) targets

let analyze_commands ~loc parsed_commands =
  (* First validate each command *)
  List.iter (validate_command ~loc) parsed_commands;

  (* Collect all targets first *)
  let all_targets = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | Some Target -> Hashtbl.replace all_targets var.name ()
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (* Collect deps: variables marked as Dep that aren't targets *)
  let deps = ref [] in
  let seen_deps = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | Some Dep when not (Hashtbl.mem all_targets var.name)
                   && not (Hashtbl.mem seen_deps var.name) ->
          Hashtbl.add seen_deps var.name ();
          deps := var.name :: !deps
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (* Collect targets in order *)
  let targets = ref [] in
  let seen_targets = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | Some Target when not (Hashtbl.mem seen_targets var.name) ->
          Hashtbl.add seen_targets var.name ();
          targets := var.name :: !targets
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (* Collect plain vars (Cmd.t) in order *)
  let plain_vars = ref [] in
  let seen_plain = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | None when not (Hashtbl.mem seen_plain var.name) ->
          Hashtbl.add seen_plain var.name ();
          plain_vars := var.name :: !plain_vars
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (List.rev !targets, List.rev !deps, List.rev !plain_vars)
```

### AST Generation using Metaquot

With `ppxlib.metaquot`, we can generate AST using natural OCaml syntax with quotations (`[%expr ...]`) and anti-quotations (`[%e ...]`).

#### Generating `[%cmd ...]`

```ocaml
let generate_cmd ~loc targets deps cmd =
  let open Ast_builder.Default in

  let targets_expr = elist ~loc (List.map (evar ~loc) targets) in
  let deps_expr = elist ~loc (List.map (evar ~loc) deps) in

  (* Build Printf.sprintf call for the command string *)
  let template_expr = estring ~loc cmd.template in
  let command_expr = match cmd.vars with
    | [] -> template_expr
    | vars ->
        let args = List.map (fun v -> evar ~loc v.name) vars in
        List.fold_left (fun acc arg ->
          [%expr [%e acc] [%e arg]]
        ) [%expr Printf.sprintf [%e template_expr]] args
  in

  [%expr Mach_build.Cmd.v
           ~targets:[%e targets_expr]
           ~deps:[%e deps_expr]
           [%e command_expr]]
```

#### Generating `[%rule ...]` with Cmd.t Composition

For rules that contain plain `{var}` references (which may be `Cmd.t` values), we need to:
1. Merge targets from all `Cmd.t` variables
2. Merge deps from all `Cmd.t` variables
3. Use `.command` field for string substitution

```ocaml
let generate_rule ~loc targets deps plain_vars commands =
  let open Ast_builder.Default in

  (* Static targets from >{...} *)
  let static_targets = List.map (evar ~loc) targets in

  (* Dynamic targets from Cmd.t variables *)
  let cmd_targets = List.map (fun name ->
    [%expr [%e evar ~loc name].Mach_build.Cmd.targets]
  ) plain_vars in

  (* Combine: static targets @ flattened cmd targets *)
  let targets_expr =
    if cmd_targets = [] then
      pexp_array ~loc static_targets
    else
      [%expr Array.of_list (List.flatten [
        [%e elist ~loc (List.map (fun e -> [%expr [[%e e]]]) static_targets)];
        [%e elist ~loc cmd_targets]
      ])]
  in

  (* Static deps from <{...} *)
  let static_deps = List.map (evar ~loc) deps in

  (* Dynamic deps from Cmd.t variables *)
  let cmd_deps = List.map (fun name ->
    [%expr [%e evar ~loc name].Mach_build.Cmd.deps]
  ) plain_vars in

  (* Combine deps *)
  let deps_expr =
    if cmd_deps = [] then
      elist ~loc static_deps
    else
      [%expr List.flatten [
        [%e elist ~loc (List.map (fun e -> [%expr [[%e e]]]) static_deps)];
        [%e elist ~loc cmd_deps]
      ]]
  in

  (* Build each command, using .command for Cmd.t variables *)
  let build_command cmd =
    let template_expr = estring ~loc cmd.template in
    let args = List.map (fun v ->
      match v.kind with
      | None -> [%expr [%e evar ~loc v.name].Mach_build.Cmd.command]
      | Some _ -> evar ~loc v.name
    ) cmd.vars in
    match args with
    | [] -> template_expr
    | _ ->
        List.fold_left (fun acc arg ->
          [%expr [%e acc] [%e arg]]
        ) [%expr Printf.sprintf [%e template_expr]] args
  in

  let commands_expr = elist ~loc (List.map build_command commands) in

  [%expr Mach_build.Rules.rule rules
           ~targets:[%e targets_expr]
           ~deps:[%e deps_expr]
           [%e commands_expr]]
```

This is much more readable than manually constructing AST nodes! The `[%expr ...]` quotation creates expression AST nodes, and `[%e ...]` anti-quotation allows embedding dynamically generated expressions.

Note: The function signature is:
```ocaml
let rule t ~targets ~deps commands = ...
```

So `rules` is the first positional argument (the rules reference), and `commands` is the last positional.

## Summary

Files to create:
1. `ppx_rule/dune` - library definition
2. `ppx_rule/ppx_rule.ml` - PPX implementation

Files to modify:
1. `lib/dune` - add ppx_rule dependency
2. `lib/mach_ocaml_rules.ml` - refactor to use [%rule ...] syntax
3. `dune-project` - add ppx_rule package (optional, can be internal)

## Open Questions

1. Should we support `dyndep` rules with a separate extension like `[%rule_dyndep ...]`?
2. Should the `rules` variable name be configurable or always assume `rules`?
3. Should we validate that variables referenced exist in scope? (Probably not - let OCaml's type checker handle that)

## Decision: Keep it Simple

For the initial implementation:
1. Always assume `rules` variable in scope
2. Only support regular rules (not dyndep)
3. Let OCaml's type checker validate variable references
4. Focus on the core use case in Mach_ocaml_rules
