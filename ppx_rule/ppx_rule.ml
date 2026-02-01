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
      let name::silent = names in
      vars := { name; kind = Target } :: !vars;
      Buffer.add_string buf "%s";
      List.iter (fun name -> vars := { name; kind = Target_silent } :: !vars) silent;
      loop ()
    | Rule_lexer.DEP names ->
      (* First dep appears in command, rest are silent.
         If first element is ONE "", all deps are silent.
         CONCAT means it's a list of deps, ONE means single dep. *)
      let add_silent = function
        | Rule_lexer.ONE "" -> ()
        | Rule_lexer.ONE name -> vars := { name; kind = Dep_silent } :: !vars
        | Rule_lexer.CONCAT name -> vars := { name; kind = Dep_silent_list } :: !vars
      in
      let name::silent = names in
      begin match name with
      | Rule_lexer.ONE "" ->
        List.iter add_silent silent
      | Rule_lexer.CONCAT name ->
        vars := { name; kind = Dep_list } :: !vars;
        Buffer.add_string buf "%s";
        List.iter add_silent silent
      | Rule_lexer.ONE name ->
        vars := { name; kind = Dep } :: !vars;
        Buffer.add_string buf "%s";
        List.iter add_silent silent
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

(** Build a Cmd.v expression from a parsed command.
    For a single command, targets/deps don't overlap (validated), so we just categorize vars. *)
let build_cmd_expr ~loc cmd =
  let open Ast_builder.Default in
  let targets = ref [] in
  let deps = ref [] in
  let dep_lists = ref [] in
  let cmd_fragments = ref [] in
  let cmd_fragment_lists = ref [] in
  let seen = Hashtbl.create 16 in
  List.iter (fun var ->
    if not (Hashtbl.mem seen var.name) then begin
      Hashtbl.add seen var.name ();
      match var.kind with
      | Target | Target_silent -> targets := var.name :: !targets
      | Dep | Dep_silent -> deps := var.name :: !deps
      | Dep_list | Dep_silent_list -> dep_lists := var.name :: !dep_lists
      | Cmd_fragment -> cmd_fragments := var.name :: !cmd_fragments
      | Cmd_fragment_list -> cmd_fragment_lists := var.name :: !cmd_fragment_lists
    end
  ) cmd.vars;
  let targets = List.rev !targets in
  let deps = List.rev !deps in
  let dep_lists = List.rev !dep_lists in
  let cmd_fragments = List.rev !cmd_fragments in
  let cmd_fragment_lists = List.rev !cmd_fragment_lists in
  let has_cmd_parts = cmd_fragments <> [] || cmd_fragment_lists <> [] in
  (* Build targets expression *)
  let targets_expr =
    if not has_cmd_parts then
      elist ~loc (List.map (evar ~loc) targets)
    else begin
      let static_parts = List.map (fun name -> [%expr [[%e evar ~loc name]]]) targets in
      let cmd_target_parts = List.map (fun name ->
        [%expr [%e evar ~loc name].Mach_build.Cmd.targets]
      ) cmd_fragments in
      let cmd_list_target_parts = List.map (fun name ->
        [%expr (Mach_build.Cmd.concat [%e evar ~loc name]).Mach_build.Cmd.targets]
      ) cmd_fragment_lists in
      [%expr List.flatten [%e elist ~loc (static_parts @ cmd_target_parts @ cmd_list_target_parts)]]
    end
  in
  (* Build deps expression *)
  let deps_expr =
    if not has_cmd_parts && dep_lists = [] then
      elist ~loc (List.map (evar ~loc) deps)
    else begin
      let static_parts = List.map (fun name -> [%expr [[%e evar ~loc name]]]) deps in
      let list_parts = List.map (evar ~loc) dep_lists in
      let cmd_dep_parts = List.map (fun name ->
        [%expr [%e evar ~loc name].Mach_build.Cmd.deps]
      ) cmd_fragments in
      let cmd_list_dep_parts = List.map (fun name ->
        [%expr (Mach_build.Cmd.concat [%e evar ~loc name]).Mach_build.Cmd.deps]
      ) cmd_fragment_lists in
      [%expr List.flatten [%e elist ~loc (static_parts @ list_parts @ cmd_dep_parts @ cmd_list_dep_parts)]]
    end
  in
  let command_expr = build_sprintf ~loc cmd in
  [%expr Mach_build.Cmd.v
           ~targets:[%e targets_expr]
           ~deps:[%e deps_expr]
           [%e command_expr]]

(** Expand [%cmd "..."] to Cmd.v expression *)
let expand_cmd ~ctxt str =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  build_cmd_expr ~loc (parse_command ~loc str)

let expand_rule ~ctxt exprs =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  if exprs = [] then Location.raise_errorf ~loc "[%%rule] requires at least a single command";
  let cmds = List.map (fun (e : expression) ->
    match e.pexp_desc with
    | Pexp_constant (Pconst_string _) -> [%expr [%cmd [%e e]]]
    | _ -> e) exprs
  in
  [%expr Mach_build.Rule.add rules [%e elist ~loc cmds]]

let expand_rule_dyndep ~ctxt exprs =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  if exprs = [] then Location.raise_errorf ~loc "[%%rule] requires at least a single command";
  let cmds = List.map (fun (e : expression) ->
    match e.pexp_desc with
    | Pexp_constant (Pconst_string _) -> [%expr [%cmd [%e e]]]
    | _ -> e) exprs
  in
  [%expr Mach_build.Rule.add_dyndep rules [%e elist ~loc cmds]]

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
    Ast_pattern.(single_expr_payload (esequence __))
    expand_rule

(* Extension for [%rule_dyndep "..."] *)
let rule_dyndep_extension =
  Extension.V3.declare "rule_dyndep"
    Extension.Context.expression
    Ast_pattern.(single_expr_payload (esequence __))
    expand_rule_dyndep

let () =
  Driver.register_transformation
    ~rules:[
      Context_free.Rule.extension cmd_extension;
      Context_free.Rule.extension rule_extension;
      Context_free.Rule.extension rule_dyndep_extension;
    ]
    "ppx_rule"
