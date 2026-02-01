open Ppxlib

(** Variable kinds in rule strings *)
type var_kind =
  | Target         (** first target, appears in command *)
  | Target_silent  (** 2nd+ targets, tracked but NOT in command *)
  | Dep            (** first dep, appears in command *)
  | Dep_list       (** dep that is a string list, appears in command via String.concat *)
  | Dep_silent     (** 2nd+ deps, tracked but NOT in command *)
  | Dep_silent_list (** silent dep that is a string list *)
  | Cmd_fragment   (** command fragment variable (Cmd.t) *)
  | Cmd_fragment_list (** command fragment list variable (Cmd.t list), uses Cmd.concat *)

type var = { name: string; kind: var_kind }

type parsed_command = {
  vars: var list;      (** all variables in order of appearance *)
  template: string;    (** command with %s substitutions *)
}

(** Parse a single command string, extracting variables and building template *)
let parse_command ~loc:_ str =
  let lexbuf = Lexing.from_string str in
  let buf = Buffer.create (String.length str) in
  let vars = ref [] in
  let rec loop () =
    match Rule_lexer.token lexbuf with
    | Rule_lexer.EOF -> ()
    | Rule_lexer.TARGET names ->
      (* First target appears in command, rest are silent *)
      List.iteri (fun idx name ->
        if idx = 0 then begin
          vars := { name; kind = Target } :: !vars;
          Buffer.add_string buf "%s"
        end else
          vars := { name; kind = Target_silent } :: !vars
      ) names;
      loop ()
    | Rule_lexer.DEP names ->
      (* First dep appears in command, rest are silent.
         If first element is ONE "", all deps are silent.
         CONCAT means it's a list of deps, ONE means single dep. *)
      let add_silent_dep = function
        | Rule_lexer.ONE "" -> ()
        | Rule_lexer.ONE name -> vars := { name; kind = Dep_silent } :: !vars
        | Rule_lexer.CONCAT name -> vars := { name; kind = Dep_silent_list } :: !vars
      in
      begin match names with
      | [] -> ()
      | Rule_lexer.ONE "" :: rest ->
        List.iter add_silent_dep rest
      | Rule_lexer.CONCAT name :: rest ->
        vars := { name; kind = Dep_list } :: !vars;
        Buffer.add_string buf "%s";
        List.iter add_silent_dep rest
      | Rule_lexer.ONE name :: rest ->
        vars := { name; kind = Dep } :: !vars;
        Buffer.add_string buf "%s";
        List.iter add_silent_dep rest
      end;
      loop ()
    | Rule_lexer.CMD_FRAGMENT (Rule_lexer.ONE name) ->
      vars := { name; kind = Cmd_fragment } :: !vars;
      Buffer.add_string buf "%s";
      loop ()
    | Rule_lexer.CMD_FRAGMENT (Rule_lexer.CONCAT name) ->
      vars := { name; kind = Cmd_fragment_list } :: !vars;
      Buffer.add_string buf "%s";
      loop ()
    | Rule_lexer.LITERAL s ->
      Buffer.add_string buf s;
      loop ()
    | Rule_lexer.PERCENT ->
      Buffer.add_string buf "%%";
      loop ()
  in
  loop ();
  { vars = List.rev !vars; template = Buffer.contents buf }

(** Validate that no variable is both target and dep in the same command *)
let validate_command ~loc cmd =
  let targets = Hashtbl.create 8 in
  let deps = Hashtbl.create 8 in
  List.iter (fun var ->
    match var.kind with
    | Target | Target_silent -> Hashtbl.replace targets var.name ()
    | Dep | Dep_list | Dep_silent | Dep_silent_list -> Hashtbl.replace deps var.name ()
    | Cmd_fragment | Cmd_fragment_list -> ()
  ) cmd.vars;
  Hashtbl.iter (fun name () ->
    if Hashtbl.mem deps name then
      Location.raise_errorf ~loc
        "Variable '%s' cannot be both target and dependency in the same command" name
  ) targets

(** Analyze multiple commands to determine overall targets, deps, and cmd fragments.
    A variable marked as dep in one command but as target in another is a target.
    Returns (targets, deps, cmd_fragments) - each list in order of first appearance. *)
let analyze_commands ~loc parsed_commands =
  (* First validate each command *)
  List.iter (validate_command ~loc) parsed_commands;

  (* Collect all targets first (from all commands) *)
  let all_targets = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | Target | Target_silent -> Hashtbl.replace all_targets var.name ()
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (* Collect targets in order of first appearance *)
  let targets = ref [] in
  let seen_targets = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | (Target | Target_silent) when not (Hashtbl.mem seen_targets var.name) ->
        Hashtbl.add seen_targets var.name ();
        targets := var.name :: !targets
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (* Collect deps: variables marked as Dep or Dep_silent that aren't targets *)
  let deps = ref [] in
  let dep_lists = ref [] in
  let seen_deps = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | (Dep | Dep_silent) when not (Hashtbl.mem all_targets var.name)
                             && not (Hashtbl.mem seen_deps var.name) ->
        Hashtbl.add seen_deps var.name ();
        deps := var.name :: !deps
      | (Dep_list | Dep_silent_list) when not (Hashtbl.mem all_targets var.name)
                          && not (Hashtbl.mem seen_deps var.name) ->
        Hashtbl.add seen_deps var.name ();
        dep_lists := var.name :: !dep_lists
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (* Collect plain vars (Cmd.t) in order *)
  let cmd_fragments = ref [] in
  let cmd_fragment_lists = ref [] in
  let seen_fragments = Hashtbl.create 16 in
  List.iter (fun cmd ->
    List.iter (fun var ->
      match var.kind with
      | Cmd_fragment when not (Hashtbl.mem seen_fragments var.name) ->
        Hashtbl.add seen_fragments var.name ();
        cmd_fragments := var.name :: !cmd_fragments
      | Cmd_fragment_list when not (Hashtbl.mem seen_fragments var.name) ->
        Hashtbl.add seen_fragments var.name ();
        cmd_fragment_lists := var.name :: !cmd_fragment_lists
      | _ -> ()
    ) cmd.vars
  ) parsed_commands;

  (List.rev !targets, List.rev !deps, List.rev !dep_lists, List.rev !cmd_fragments, List.rev !cmd_fragment_lists)

(** Build a Printf.sprintf call for a command template *)
let build_sprintf ~loc cmd =
  let open Ast_builder.Default in
  let template_expr = estring ~loc cmd.template in
  (* Filter out silent vars since they don't appear in the template *)
  let visible_vars = List.filter (fun v ->
    match v.kind with
    | Target_silent | Dep_silent | Dep_silent_list -> false
    | _ -> true
  ) cmd.vars in
  match visible_vars with
  | [] -> template_expr
  | vars ->
    let args = List.map (fun v ->
      match v.kind with
      | Cmd_fragment ->
        (* For Cmd.t fragments, access the .command field *)
        [%expr [%e evar ~loc v.name].Mach_build.Cmd.command]
      | Cmd_fragment_list ->
        (* For Cmd.t list fragments, concat and access .command field *)
        [%expr (Mach_build.Cmd.concat [%e evar ~loc v.name]).Mach_build.Cmd.command]
      | Target | Dep ->
        evar ~loc v.name
      | Dep_list ->
        (* For string list deps, concat with space *)
        [%expr String.concat " " [%e evar ~loc v.name]]
      | Target_silent | Dep_silent | Dep_silent_list ->
        assert false  (* filtered out above *)
    ) vars in
    List.fold_left (fun acc arg ->
      [%expr [%e acc] [%e arg]]
    ) [%expr Printf.sprintf [%e template_expr]] args

type target_format = As_list | As_array

(** Build targets and deps expressions from analyzed command data.
    Returns (targets_expr, deps_expr, commands_expr) *)
let build_rule_exprs ~loc ~target_format ~targets ~deps ~dep_lists ~cmd_fragments ~cmd_fragment_lists parsed_commands =
  let open Ast_builder.Default in

  let has_cmd_parts = cmd_fragments <> [] || cmd_fragment_lists <> [] in

  (* Build targets expression *)
  let targets_expr =
    if not has_cmd_parts then
      (* Simple case: just static targets *)
      let items = List.map (evar ~loc) targets in
      match target_format with
      | As_list -> elist ~loc items
      | As_array -> pexp_array ~loc items
    else begin
      (* Complex case: merge static targets with Cmd.t targets *)
      let static_parts = List.map (fun name ->
        [%expr [[%e evar ~loc name]]]
      ) targets in
      let cmd_target_parts = List.map (fun name ->
        [%expr [%e evar ~loc name].Mach_build.Cmd.targets]
      ) cmd_fragments in
      let cmd_list_target_parts = List.map (fun name ->
        [%expr (Mach_build.Cmd.concat [%e evar ~loc name]).Mach_build.Cmd.targets]
      ) cmd_fragment_lists in
      let flattened = [%expr List.flatten [%e elist ~loc (static_parts @ cmd_target_parts @ cmd_list_target_parts)]] in
      match target_format with
      | As_list -> flattened
      | As_array -> [%expr Array.of_list [%e flattened]]
    end
  in

  (* Build deps expression *)
  let deps_expr =
    if not has_cmd_parts && dep_lists = [] then
      (* Simple case: just static deps as list *)
      elist ~loc (List.map (evar ~loc) deps)
    else begin
      (* Complex case: merge static deps with Cmd.t deps and list deps *)
      let static_parts = List.map (fun name ->
        [%expr [[%e evar ~loc name]]]
      ) deps in
      let list_parts = List.map (fun name ->
        evar ~loc name
      ) dep_lists in
      let cmd_dep_parts = List.map (fun name ->
        [%expr [%e evar ~loc name].Mach_build.Cmd.deps]
      ) cmd_fragments in
      let cmd_list_dep_parts = List.map (fun name ->
        [%expr (Mach_build.Cmd.concat [%e evar ~loc name]).Mach_build.Cmd.deps]
      ) cmd_fragment_lists in
      [%expr List.flatten [%e elist ~loc (static_parts @ list_parts @ cmd_dep_parts @ cmd_list_dep_parts)]]
    end
  in

  (* Build commands list *)
  let commands_expr = elist ~loc (List.map (build_sprintf ~loc) parsed_commands) in

  (targets_expr, deps_expr, commands_expr)

(** Expand [%cmd "..."] to Cmd.v expression *)
let expand_cmd ~ctxt str =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let cmd = parse_command ~loc str in
  validate_command ~loc cmd;
  let targets, deps, dep_lists, cmd_fragments, cmd_fragment_lists = analyze_commands ~loc [cmd] in
  let targets_expr, deps_expr, commands_expr =
    build_rule_exprs ~loc ~target_format:As_list
      ~targets ~deps ~dep_lists ~cmd_fragments ~cmd_fragment_lists [cmd]
  in

  (* For [%cmd], we have a single command, extract it from the list *)
  let command_expr = match commands_expr.pexp_desc with
    | Pexp_construct (_, Some { pexp_desc = Pexp_tuple [hd; _]; _ }) -> hd
    | _ -> commands_expr  (* fallback, shouldn't happen *)
  in

  [%expr Mach_build.Cmd.v
           ~targets:[%e targets_expr]
           ~deps:[%e deps_expr]
           [%e command_expr]]

(** Expand [%rule "..."] or [%rule "..."; "..."] to Rule.rule call *)
let expand_rule ~ctxt payload =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  (* Extract command strings from payload *)
  let command_strings = match payload with
    | PStr items ->
      List.filter_map (fun item ->
        match item.pstr_desc with
        | Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _) ->
          Some s
        | Pstr_eval ({ pexp_desc = Pexp_apply (
            { pexp_desc = Pexp_constant (Pconst_string (s1, _, _)); _ },
            args); _ }, _) ->
          (* Handle semicolon-separated strings: "a"; "b" becomes apply *)
          let strings = s1 :: List.filter_map (fun (_, e) ->
            match e.pexp_desc with
            | Pexp_constant (Pconst_string (s, _, _)) -> Some s
            | _ -> None
          ) args in
          Some (String.concat "" strings)
        | _ -> None
      ) items
    | _ -> Location.raise_errorf ~loc "[%%rule] expects string literal(s)"
  in

  if command_strings = [] then
    Location.raise_errorf ~loc "[%%rule] requires at least one command string";

  (* Parse all commands *)
  let parsed_commands = List.map (parse_command ~loc) command_strings in

  (* Analyze to get targets, deps, dep_lists, and cmd fragments *)
  let targets, deps, dep_lists, cmd_fragments, cmd_fragment_lists = analyze_commands ~loc parsed_commands in

  let targets_expr, deps_expr, commands_expr =
    build_rule_exprs ~loc ~target_format:As_array
      ~targets ~deps ~dep_lists ~cmd_fragments ~cmd_fragment_lists parsed_commands
  in

  [%expr Mach_build.Rule.rule rules
           ~targets:[%e targets_expr]
           ~deps:[%e deps_expr]
           [%e commands_expr]]

(** Expand [%rule_dyndep "..."] to Rule.rule_dyndep call.
    Must have exactly one target. Cmd.t fragments are supported for command text
    and their deps are merged, but their targets are ignored (rule_dyndep has single target). *)
let expand_rule_dyndep ~ctxt payload =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  (* Extract command strings from payload *)
  let command_strings = match payload with
    | PStr items ->
      List.filter_map (fun item ->
        match item.pstr_desc with
        | Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _) ->
          Some s
        | Pstr_eval ({ pexp_desc = Pexp_apply (
            { pexp_desc = Pexp_constant (Pconst_string (s1, _, _)); _ },
            args); _ }, _) ->
          let strings = s1 :: List.filter_map (fun (_, e) ->
            match e.pexp_desc with
            | Pexp_constant (Pconst_string (s, _, _)) -> Some s
            | _ -> None
          ) args in
          Some (String.concat "" strings)
        | _ -> None
      ) items
    | _ -> Location.raise_errorf ~loc "[%%rule_dyndep] expects string literal(s)"
  in

  if command_strings = [] then
    Location.raise_errorf ~loc "[%%rule_dyndep] requires at least one command string";

  (* Parse all commands *)
  let parsed_commands = List.map (parse_command ~loc) command_strings in

  (* Analyze to get targets, deps, dep_lists, and cmd fragments *)
  let targets, deps, dep_lists, cmd_fragments, cmd_fragment_lists = analyze_commands ~loc parsed_commands in

  (* rule_dyndep requires exactly one static target *)
  if List.length targets <> 1 then
    Location.raise_errorf ~loc "[%%rule_dyndep] requires exactly one target";

  let target_expr = evar ~loc (List.hd targets) in

  let has_cmd_parts = cmd_fragments <> [] || cmd_fragment_lists <> [] in

  (* Build deps expression - merge static deps with Cmd.t deps and list deps *)
  let deps_expr =
    if not has_cmd_parts && dep_lists = [] then
      elist ~loc (List.map (evar ~loc) deps)
    else begin
      let static_parts = List.map (fun name ->
        [%expr [[%e evar ~loc name]]]
      ) deps in
      let list_parts = List.map (fun name ->
        evar ~loc name
      ) dep_lists in
      let cmd_dep_parts = List.map (fun name ->
        [%expr [%e evar ~loc name].Mach_build.Cmd.deps]
      ) cmd_fragments in
      let cmd_list_dep_parts = List.map (fun name ->
        [%expr (Mach_build.Cmd.concat [%e evar ~loc name]).Mach_build.Cmd.deps]
      ) cmd_fragment_lists in
      [%expr List.flatten [%e elist ~loc (static_parts @ list_parts @ cmd_dep_parts @ cmd_list_dep_parts)]]
    end
  in

  (* Build commands list *)
  let commands_expr = elist ~loc (List.map (build_sprintf ~loc) parsed_commands) in

  [%expr Mach_build.Rule.rule_dyndep rules
           ~target:[%e target_expr]
           ~deps:[%e deps_expr]
           [%e commands_expr]]

(* Extension for [%cmd "..."] *)
let cmd_extension =
  Extension.V3.declare "cmd"
    Extension.Context.expression
    Ast_pattern.(single_expr_payload (estring __))
    expand_cmd

(* Extension for [%rule "..."] or [%rule "..."; "..."] *)
let rule_extension =
  Extension.V3.declare "rule"
    Extension.Context.expression
    Ast_pattern.(__')
    (fun ~ctxt payload -> expand_rule ~ctxt payload.txt)

(* Extension for [%rule_dyndep "..."] *)
let rule_dyndep_extension =
  Extension.V3.declare "rule_dyndep"
    Extension.Context.expression
    Ast_pattern.(__')
    (fun ~ctxt payload -> expand_rule_dyndep ~ctxt payload.txt)

let () =
  Driver.register_transformation
    ~rules:[
      Context_free.Rule.extension cmd_extension;
      Context_free.Rule.extension rule_extension;
      Context_free.Rule.extension rule_dyndep_extension;
    ]
    "ppx_rule"
