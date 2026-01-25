open! Printf
open! Mach_std

let modname_of path = Filename.(basename path |> remove_extension)

let capture_outf fmt = ksprintf (sprintf "${MACH} run-build-command -- %s") fmt
let capture_stderrf fmt = ksprintf (sprintf "${MACH} run-build-command --stderr-only -- %s") fmt

let preprocess_ocaml_module ninja cfg ~build_dir ~path_ml ~path_mli ~kind =
  let mach = cfg.Mach_config.mach_executable_path in
  let modname = modname_of path_ml in
  let ml = Filename.(build_dir / modname ^ ".ml") in
  let pp_flag = match kind with Mach_module.ML -> "" | MLX -> " --pp mlx-pp" in
  Ninja.rulef ninja ~target:ml ~deps:[path_ml] "%s pp%s -o %s %s" mach pp_flag ml path_ml;
  let mli =
    Option.map (fun mli_path ->
      let mli = Filename.(build_dir / modname ^ ".mli") in
      Ninja.rulef ninja ~target:mli ~deps:[mli_path] "%s pp -o %s %s" mach mli mli_path;
      mli) path_mli
  in
  ml, mli

let ocamldep ninja cfg ~build_dir ~path_ml ~includes_args =
  let mach = cfg.Mach_config.mach_executable_path in
  let modname = modname_of path_ml in
  let path_dep = Filename.(build_dir / modname ^ ".dep") in
  Ninja.rulef ninja ~target:path_dep ~deps:[path_ml; includes_args]
    "%s dep %s -o %s --args %s" mach path_ml path_dep includes_args;
  path_dep

let compile_ocaml_args ?(include_self=false) ninja cfg ~requires ~build_dir ~deps =
  let build_dir_of = Mach_config.build_dir_of cfg in
  let args = Filename.(build_dir / "includes.args") in
  let path_requires, extlib_requires =
    List.partition_map (function
    | Mach_module.Require r | Mach_module.Require_lib r -> Either.Left r
    | Mach_module.Require_extlib lib -> Right lib
  ) requires in
  let recipe =
    match include_self, path_requires, extlib_requires with
    | false, [], [] -> [sprintf "touch %s" args]
    | _ ->
      let of_self =
        if include_self then [sprintf "echo '-I=%s' >> %s" build_dir args]
        else []
      in
      let of_path =
        List.map
          (fun (r : _ with_loc) -> sprintf "echo '-I=%s' >> %s" (build_dir_of r.v) args)
          path_requires
      in
      let of_libs =
        match extlib_requires with
        | [] -> []
        | libs ->
          let libs = String.concat " " (List.map (fun (l : Mach_module.extlib with_loc) -> l.v.name) libs) in
          [capture_stderrf "ocamlfind query -format '-I=%%d' -recursive %s >> %s" libs args]
      in
      of_libs @ of_self @ of_path
  in
  Ninja.rule ninja ~target:args ~deps (sprintf "rm -f %s" args :: recipe);
  args

let compile_ocaml_module ?dyndep ninja cfg ~build_dir ~path_ml ~path_mli ~requires =
  let build_dir_of = Mach_config.build_dir_of cfg in
  let modname = modname_of path_ml in
  let ml = Filename.(build_dir / modname ^ ".ml") in
  let mli = Filename.(build_dir / modname ^ ".mli") in
  let cmi = Filename.(build_dir / modname ^ ".cmi") in
  let cmx = Filename.(build_dir / modname ^ ".cmx") in
  let cmt = Filename.(build_dir / modname ^ ".cmt") in
  let includes_args = Filename.(build_dir / "includes.args") in
  let deps = List.filter_map (function
    | Mach_module.Require r -> Some Filename.(build_dir_of r.v / modname_of r.v ^ ".cmi")
    | Mach_module.Require_lib r -> Some Filename.(build_dir_of r.v / Filename.basename r.v ^ ".cmxa")
    | Mach_module.Require_extlib _ -> None
  ) requires in
  begin match path_mli with
  | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first (using ocamlc for speed), then .ml to .cmx *)
    Ninja.rule ninja ~target:cmi ~deps:(mli :: includes_args :: deps)
      [capture_outf "ocamlc -bin-annot -c -opaque -args %s -o %s %s" includes_args cmi mli];
    Ninja.rule ninja ~target:cmx ~deps:[ml; cmi; includes_args] ?dyndep
      [capture_outf "ocamlopt -bin-annot -c -args %s -cmi-file %s -o %s -impl %s" includes_args cmi cmx ml];
    Ninja.rule ninja ~target:cmt ~deps:[cmx] []
  | None -> (* Without .mli: ocamlopt produces both .cmi and .cmx *)
    Ninja.rule ninja ~target:cmx ~deps:(ml :: includes_args :: deps) ?dyndep
      [capture_outf "ocamlopt -bin-annot -c -args %s -o %s -impl %s" includes_args cmx ml];
    Ninja.rule ninja ~target:cmi ~deps:[cmx] [];
    Ninja.rule ninja ~target:cmt ~deps:[cmx] []
  end;
  cmi, cmx

let link_ocaml_executable ninja cfg ~build_dir ~(cmxs : string list) ~(cmxas : string list) ~(extlibs : string list) ~exe_path =
  let objs = cmxas @ cmxs in
  let objs_args = Filename.(build_dir / "objs.args") in
  Ninja.rulef ninja ~target:objs_args ~deps:objs
    "printf '%%s\\n' %s > %s" (String.concat " " objs) objs_args;
  match extlibs with
  | [] ->
    Ninja.rule ninja ~target:exe_path ~deps:[objs_args]
      [capture_outf "ocamlopt -o %s -args %s" exe_path objs_args]
  | libs ->
    let lib_objs_args = Filename.(build_dir / "lib_objs.args") in
    let libs = String.concat " " libs in
    Ninja.rule ninja ~target:lib_objs_args ~deps:[]
      [capture_stderrf "ocamlfind query -a-format -recursive -predicates native %s > %s" libs lib_objs_args];
    Ninja.rule ninja ~target:exe_path ~deps:[objs_args; lib_objs_args]
      [capture_outf "ocamlopt -o %s -args %s -args %s" exe_path lib_objs_args objs_args]

let link_ocaml_library ninja cfg ~build_dir ~(cmxs : string list) ~deps ~lib_name =
  let mach = cfg.Mach_config.mach_executable_path in
  let all_deps_sorted = Filename.(build_dir / lib_name ^ ".link-deps") in
  Ninja.rulef ninja ~target:all_deps_sorted ~deps:deps
    "%s link-deps %s > %s" mach (String.concat " " deps) all_deps_sorted;
  let cmxa = Filename.(build_dir / lib_name ^ ".cmxa") in
  let cmxa_a = Filename.(build_dir / lib_name ^ ".a") in
  Ninja.rule ninja ~target:cmxa ~deps:(all_deps_sorted :: cmxs)
    [capture_outf "ocamlopt -a -o %s -args %s" cmxa all_deps_sorted];
  Ninja.rule ninja ~target:cmxa_a ~deps:[cmxa] [];
