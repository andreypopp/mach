open! Printf
open! Mach_std

let modname_of path = Filename.(basename path |> remove_extension)

let cmdf fmt = ksprintf Fun.id fmt

let preprocess_ocaml_module rules cfg ~build_dir ~path_ml ~path_mli ~kind =
  let mach = cfg.Mach_config.mach_executable_path in
  let modname = modname_of path_ml in
  let ml = Filename.(build_dir / modname ^ ".ml") in
  let pp_flag = match kind with Mach_module.ML -> "" | MLX -> " --pp mlx-pp" in
  Mach_build.Rules.rulef rules ~targets:[|ml|] ~deps:[path_ml] "%s pp%s -o %s %s" mach pp_flag ml path_ml;
  let mli =
    Option.map (fun mli_path ->
      let mli = Filename.(build_dir / modname ^ ".mli") in
      Mach_build.Rules.rulef rules ~targets:[|mli|] ~deps:[mli_path] "%s pp -o %s %s" mach mli mli_path;
      mli) path_mli
  in
  ml, mli

let ocamldep rules cfg ~build_dir ~path_ml ~includes_args =
  let mach = cfg.Mach_config.mach_executable_path in
  let modname = modname_of path_ml in
  let path_dep = Filename.(build_dir / modname ^ ".dep") in
  Mach_build.Rules.rule_dyndep rules ~target:path_dep ~deps:[path_ml; includes_args]
    [sprintf "%s dep %s -o %s --args %s" mach path_ml path_dep includes_args];
  path_dep

(** Generate include args files for compilation.
    Returns (ocamldep_args, compile_args) where:
    - ocamldep_args: only mach-managed paths (for dependency scanning)
    - compile_args: all paths including extlibs (for compilation) *)
let compile_ocaml_args ?(include_self=false) rules cfg ~requires ~build_dir ~deps =
  let build_dir_of = Mach_config.build_dir_of cfg in
  let ocamldep_args = Filename.(build_dir / "ocamldep.args") in
  let compile_args = Filename.(build_dir / "includes.args") in
  let path_requires, extlib_requires =
    List.partition_map (function
    | Mach_module.Require r | Mach_module.Require_lib r -> Either.Left r
    | Mach_module.Require_extlib lib -> Right lib
  ) requires in
  (* ocamldep.args: only mach-managed paths *)
  let ocamldep_recipe =
    match include_self, path_requires with
    | false, [] -> [sprintf "touch %s" ocamldep_args]
    | _ ->
      let of_self =
        if include_self then [sprintf "echo '-I=%s' >> %s" build_dir ocamldep_args]
        else []
      in
      let of_path =
        List.map
          (fun (r : _ with_loc) -> sprintf "echo '-I=%s' >> %s" (build_dir_of r.v) ocamldep_args)
          path_requires
      in
      of_self @ of_path
  in
  Mach_build.Rules.rule rules ~targets:[|ocamldep_args|] ~deps (sprintf "rm -f %s" ocamldep_args :: ocamldep_recipe);
  (* includes.args: all paths including extlibs *)
  let compile_recipe =
    match include_self, path_requires, extlib_requires with
    | false, [], [] -> [sprintf "touch %s" compile_args]
    | _ ->
      let of_self =
        if include_self then [sprintf "echo '-I=%s' >> %s" build_dir compile_args]
        else []
      in
      let of_path =
        List.map
          (fun (r : _ with_loc) -> sprintf "echo '-I=%s' >> %s" (build_dir_of r.v) compile_args)
          path_requires
      in
      let of_libs =
        match extlib_requires with
        | [] -> []
        | libs ->
          let libs = String.concat " " (List.map (fun (l : Mach_module.extlib with_loc) -> l.v.name) libs) in
          [cmdf "ocamlfind query -format '-I=%%d' -recursive %s >> %s" libs compile_args]
      in
      of_libs @ of_self @ of_path
  in
  Mach_build.Rules.rule rules ~targets:[|compile_args|] ~deps (sprintf "rm -f %s" compile_args :: compile_recipe);
  ocamldep_args, compile_args

let compile_ocaml_module ?dyndep rules cfg ~build_dir ~path_ml ~path_mli ~requires =
  let build_dir_of = Mach_config.build_dir_of cfg in
  let modname = modname_of path_ml in
  let ml = Filename.(build_dir / modname ^ ".ml") in
  let mli = Filename.(build_dir / modname ^ ".mli") in
  let cmi = Filename.(build_dir / modname ^ ".cmi") in
  let cmx = Filename.(build_dir / modname ^ ".cmx") in
  let cmt = Filename.(build_dir / modname ^ ".cmt") in
  let cmti = Filename.(build_dir / modname ^ ".cmti") in
  let o = Filename.(build_dir / modname ^ ".o") in
  let includes_args = Filename.(build_dir / "includes.args") in
  let deps = List.filter_map (function
    | Mach_module.Require r -> Some Filename.(build_dir_of r.v / modname_of r.v ^ ".cmi")
    | Mach_module.Require_lib r -> Some Filename.(build_dir_of r.v / Filename.basename r.v ^ ".cmxa")
    | Mach_module.Require_extlib _ -> None
  ) requires in
  let add_dyndep deps = match dyndep with None -> deps | Some d -> d :: deps in
  begin match path_mli with
  | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first (using ocamlc for speed), then .ml to .cmx *)
    Mach_build.Rules.rule rules ~targets:[|cmi; cmti|] ~deps:(mli :: includes_args :: deps)
      [cmdf "ocamlc -bin-annot -c -opaque -args %s -o %s %s" includes_args cmi mli];
    Mach_build.Rules.rule rules ~targets:[|cmx; o; cmt|] ~deps:(add_dyndep [ml; cmi; includes_args])
      [cmdf "ocamlopt -bin-annot -c -args %s -cmi-file %s -o %s -impl %s" includes_args cmi cmx ml]
  | None -> (* Without .mli: ocamlopt produces both .cmi and .cmx *)
    Mach_build.Rules.rule rules ~targets:[|cmx; cmi; o; cmt|] ~deps:(add_dyndep (ml :: includes_args :: deps))
      [cmdf "ocamlopt -bin-annot -c -args %s -o %s -impl %s" includes_args cmx ml]
  end;
  cmi, cmx

let link_ocaml_executable rules _cfg ~build_dir ~(objs : string list) ~(extlibs : string list) ~exe_path =
  let objs_args = Filename.(build_dir / "objs.args") in
  Mach_build.Rules.rulef rules ~targets:[|objs_args|] ~deps:objs
    "printf '%%s\\n' %s > %s" (String.concat " " objs) objs_args;
  match extlibs with
  | [] ->
    Mach_build.Rules.rule rules ~targets:[|exe_path|] ~deps:[objs_args]
      [cmdf "ocamlopt -o %s -args %s" exe_path objs_args]
  | libs ->
    let lib_objs_args = Filename.(build_dir / "lib_objs.args") in
    let libs = String.concat " " libs in
    Mach_build.Rules.rule rules ~targets:[|lib_objs_args|] ~deps:[]
      [cmdf "ocamlfind query -a-format -recursive -predicates native %s > %s" libs lib_objs_args];
    Mach_build.Rules.rule rules ~targets:[|exe_path|] ~deps:[objs_args; lib_objs_args]
      [cmdf "ocamlopt -o %s -args %s -args %s" exe_path lib_objs_args objs_args]

let link_ocaml_library rules cfg ~build_dir ~(cmxs : string list) ~deps ~lib_name =
  let mach = cfg.Mach_config.mach_executable_path in
  let all_deps_sorted = Filename.(build_dir / lib_name ^ ".link-deps") in
  Mach_build.Rules.rulef rules ~targets:[|all_deps_sorted|] ~deps:deps
    "%s link-deps %s > %s" mach (String.concat " " deps) all_deps_sorted;
  let cmxa = Filename.(build_dir / lib_name ^ ".cmxa") in
  let cmxa_a = Filename.(build_dir / lib_name ^ ".a") in
  Mach_build.Rules.rule rules ~targets:[|cmxa; cmxa_a|] ~deps:(all_deps_sorted :: cmxs)
    [cmdf "ocamlopt -a -o %s -args %s" cmxa all_deps_sorted]
