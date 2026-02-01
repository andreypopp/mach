open! Printf
open! Mach_std
open! Mach_build

let modname_of path = Filename.(basename path |> remove_extension)

let cmdf fmt = ksprintf Fun.id fmt

let preprocess_ocaml_module rules cfg ~build_dir ~path_ml ~path_mli ~kind ?ppx_driver () =
  let mach = Cmd.v cfg.Mach_config.mach_executable_path in
  let modname = modname_of path_ml in
  let ml = Filename.(build_dir / modname ^ ".ml") in
  let pp_mlx = match kind with Mach_module.ML -> [%cmd ""] | MLX -> [%cmd " --pp mlx-pp"] in
  let pp_ppx = match ppx_driver with None -> [%cmd ""] | Some exe -> [%cmd " --pp <{exe}"] in
  [%rule "%{mach} pp %{pp_mlx} %{pp_ppx} -o >{ml} <{path_ml}"];
  let mli =
    Option.map (fun path_mli ->
      let mli = Filename.(build_dir / modname ^ ".mli") in
      [%rule "%{mach} pp %{pp_ppx} -o >{mli} <{path_mli}"];
      mli) path_mli
  in
  ml, mli

let ocamldep rules cfg ~build_dir ~path_ml ~includes_args =
  let mach = Cmd.v cfg.Mach_config.mach_executable_path in
  let path_dep = Filename.(build_dir / modname_of path_ml ^ ".dep") in
  [%rule_dyndep "%{mach} dep <{path_ml} -o >{path_dep} --args <{includes_args}"];
  path_dep

(** Generate include args files for compilation.
    Returns (ocamldep_args, compile_args) where:
    - ocamldep_args: only mach-managed paths (for dependency scanning)
    - compile_args: all paths including extlibs (for compilation) *)
let compile_ocaml_args ?(include_self=false) rules cfg ~requires ~build_dir ~deps =
  let build_dir_of = Mach_config.build_dir_of cfg in
  let dirs, libs =
    List.partition_map (function
    | Mach_module.Require r | Mach_module.Require_lib r -> Either.Left (Cmd.v (build_dir_of r.v))
    | Mach_module.Require_extlib lib -> Right (Cmd.v lib.v.name)
  ) requires in
  let dirs = if include_self then Cmd.v build_dir :: dirs else dirs in
  let ocamldep_args =
    let target = Filename.(build_dir / "ocamldep.args") in
    let cmds =
      match dirs with
      | [] -> [[%cmd "touch >{target}"]]
      | _ -> List.map (fun dir -> [%cmd "echo '-I=%{dir}' >> >{target}"]) dirs
    in
    let cmds = [%cmd "rm -f >{target} <{|deps...}"] :: cmds in
    Rule.add rules cmds;
    target
  in
  let includes_args =
    let target = Filename.(build_dir / "includes.args") in
    let cmds =
      match dirs, libs with
      | [], [] -> [[%cmd "touch >{target}"]]
      | _ ->
        let of_path = List.map (fun dir -> [%cmd "echo '-I=%{dir}' >> >{target}"]) dirs in
        if libs = [] then of_path else
        [%cmd "ocamlfind query -format '-I=%d' -recursive %{libs...} >> >{target}"]::of_path
    in
    let cmds = [%cmd "rm -f >{target} <{|deps...}"] :: cmds in
    Rule.add rules cmds;
    target
  in
  ocamldep_args, includes_args

let compile_ocaml_module ?dyndep rules cfg ~build_dir ~path_ml ~path_mli ~requires =
  let build_dir_of = Mach_config.build_dir_of cfg in
  let modname = modname_of path_ml in
  let ml    = Filename.(build_dir / modname ^ ".ml") in
  let mli   = Filename.(build_dir / modname ^ ".mli") in
  let cmi   = Filename.(build_dir / modname ^ ".cmi") in
  let cmx   = Filename.(build_dir / modname ^ ".cmx") in
  let cmt   = Filename.(build_dir / modname ^ ".cmt") in
  let cmti  = Filename.(build_dir / modname ^ ".cmti") in
  let o     = Filename.(build_dir / modname ^ ".o") in
  let includes_args = Filename.(build_dir / "includes.args") in
  let deps = List.filter_map (function
    | Mach_module.Require r -> Some Filename.(build_dir_of r.v / modname_of r.v ^ ".cmi")
    | Mach_module.Require_lib r -> Some Filename.(build_dir_of r.v / Filename.basename r.v ^ ".cmxa")
    | Mach_module.Require_extlib _ -> None
  ) requires in
  let dyndep = Option.to_list dyndep in
  begin match path_mli with
  | Some _ -> (* With .mli: compile .mli to .cmi/.cmti first (using ocamlc for speed), then .ml to .cmx *)
    [%rule "ocamlc -bin-annot -c -opaque -args <{includes_args} -o >{cmi|cmti} <{mli|deps...}"];
    [%rule "ocamlopt -bin-annot -c -args <{includes_args} -cmi-file <{cmi} -o >{cmx|cmt|o} -impl <{ml|dyndep...}"];
  | None -> (* Without .mli: ocamlopt produces both .cmi and .cmx *)
    [%rule "ocamlopt -bin-annot -c -args <{includes_args} -o >{cmx|cmi|cmt|o} -impl <{ml|deps...|dyndep...}"]
  end;
  cmi, cmx

let link_ocaml_executable rules _cfg ~build_dir ~(objs : string list) ~(extlibs : string list) ~exe_path =
  let objs_args = Filename.(build_dir / "objs.args") in
  [%rule "printf '%s\n' <{objs...} > >{objs_args}"];
  match extlibs with
  | [] ->
    [%rule "ocamlopt -o >{exe_path} -args <{objs_args}"]
  | libs ->
    let lib_objs_args = Filename.(build_dir / "lib_objs.args") in
    let cclib_args = Filename.(build_dir / "cclib.args") in
    let libs = List.map Cmd.v libs in
    [%rule "ocamlfind query -a-format -recursive -predicates native %{libs...} > >{lib_objs_args}"];
    [%rule "ocamlfind query -l-format -recursive -predicates native %{libs...} | tr ' ' '\n' > >{cclib_args}"];
    [%rule "ocamlopt -o >{exe_path} -args <{lib_objs_args} -args <{cclib_args} -args <{objs_args}"]

let link_ocaml_library rules cfg ~build_dir ~(cmxs : string list) ~deps ~lib_name =
  let mach = Cmd.v cfg.Mach_config.mach_executable_path in
  let link_deps = Filename.(build_dir / lib_name ^ ".link-deps") in
  let cmxa      = Filename.(build_dir / lib_name ^ ".cmxa") in
  let cmxa_a    = Filename.(build_dir / lib_name ^ ".a") in
  [%rule "%{mach} link-deps <{deps...} > >{link_deps}"];
  [%rule "ocamlopt -a -o >{cmxa|cmxa_a} -args <{link_deps|cmxs...}"]

(** Compile a ppx driver executable in build_dir/_ppx. *)
let compile_ppx_driver rules _cfg ~build_dir ~ppxes =
  if ppxes = [] then None else
  let ppx_dir             = Filename.(build_dir / "_ppx") in
  let driver_ml           = Filename.(ppx_dir / "driver.ml") in
  let driver_exe          = Filename.(ppx_dir / "driver.exe") in
  let driver_cmi          = Filename.(ppx_dir / "driver.cmi") in
  let driver_cmx          = Filename.(ppx_dir / "driver.cmx") in
  let includes_args       = Filename.(ppx_dir / "includes.args") in
  let lib_objs_args       = Filename.(ppx_dir / "lib_objs.args") in
  let cclib_args          = Filename.(ppx_dir / "cclib.args") in
  let libs = List.map (fun (Mach_module.Ppx_extlib lib) -> Cmd.v lib.v.name) ppxes in
  [%rule "mkdir -p >{ppx_dir}"];
  [%rule "echo 'let () = Ppxlib.Driver.standalone ()' > >{driver_ml} <{|ppx_dir}"];
  [%rule "ocamlfind query -predicates ppx_driver,native -format '-I=%d' -recursive %{libs...} >> >{includes_args} <{|ppx_dir}"];
  [%rule "ocamlfind query -a-format -recursive -predicates ppx_driver,native %{libs...} > >{lib_objs_args} <{|ppx_dir}"];
  [%rule "ocamlfind query -l-format -recursive -predicates ppx_driver,native %{libs...} | tr ' ' '\n' > >{cclib_args} <{|ppx_dir}"];
  [%rule "ocamlopt -c -args <{includes_args} -o >{driver_cmx|driver_cmi} <{driver_ml}"];
  [%rule "ocamlopt -linkall -o >{driver_exe} -args <{lib_objs_args} -args <{cclib_args} <{driver_cmx}"];
  Some driver_exe
