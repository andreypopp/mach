# Implement Proper Preprocessing Pipeline

## Problem Statement

Currently, mach preprocesses each module in two separate places:

1. **Build-time preprocessing**: During configure, ninja rules are generated that run `mach pp <src> > build/<src>` to strip shebang and `#require` directives (see `lib/mach_lib.ml:55-58`)

2. **Compile-time preprocessing**: For `.mlx` files, the compiler is invoked with `-pp mlx-pp` flag (see `lib/mach_lib.ml:79,88,90,93,94`), which runs `mlx-pp` again during compilation

This means `.mlx` files are preprocessed **twice** - once by `mach pp` and once by `mlx-pp`. This is inefficient and creates issues for future use cases like feeding preprocessed output to `ocamldep`.

## Goal

Implement preprocessing via the build system so that:
1. Preprocessing happens exactly once
2. The preprocessed output can be reused by multiple consumers (ocamldep, compiler)
3. The compiler is invoked without `-pp` flag on already-preprocessed files

## Current Flow

```
source.ml  → mach pp → build/source.ml → ocamlopt               → source.cmx
source.mlx → mach pp → build/source.mlx → ocamlopt -pp mlx-pp   → source.cmx
```

## Proposed Flow

```
source.ml  → mach pp                    → build/source.ml  → ocamlopt → source.cmx
source.mlx → mach pp --pp 'mlx-pp'      → build/source.ml  → ocamlopt → source.cmx
```

Note: For `.mlx` files, the preprocessed output is `.ml` (not `.mlx`) since `mlx-pp` transforms MLX syntax to plain OCaml.

## Implementation Plan

### Step 1: Extend `mach pp` command to accept `--pp` option

Modify `bin/mach.ml` to add a `--pp` option to the `pp` subcommand:

```ocaml
let pp_cmd =
  let doc = "Preprocess source file to stdout (for use with merlin -pp)" in
  let info = Cmd.info "pp" ~doc ~docs:Manpage.s_none in
  let pp_arg = Arg.(value & opt (some string) None & info ["pp"]
    ~docv:"COMMAND" ~doc:"External preprocessor to run after mach preprocessing") in
  Cmd.v info Term.(const pp $ source_arg $ pp_arg)
```

### Step 2: Modify `Mach_lib.pp` to pipe through external preprocessor

Update `lib/mach_lib.ml`:

```ocaml
let pp ?pp_cmd source_path =
  let mach_pp oc ic = Mach_module.preprocess_source ~source_path oc ic in
  match pp_cmd with
  | None ->
    In_channel.with_open_text source_path (mach_pp stdout);
    flush stdout
  | Some cmd ->
    (* Pipe through external preprocessor *)
    let ic, oc = Unix.open_process cmd in
    In_channel.with_open_text source_path (mach_pp oc);
    close_out oc;
    (* Copy external preprocessor output to stdout *)
    let rec copy () =
      match In_channel.input_line ic with
      | Some line -> print_endline line; copy ()
      | None -> ()
    in
    copy ();
    match Unix.close_process (ic, oc) with
    | Unix.WEXITED 0 -> ()
    | _ -> Mach_error.user_errorf "preprocessor %S failed" cmd
```

**Alternative implementation** using temporary file (simpler, more robust):

```ocaml
let pp ?pp_cmd source_path =
  match pp_cmd with
  | None ->
    In_channel.with_open_text source_path (fun ic ->
      Mach_module.preprocess_source ~source_path stdout ic);
    flush stdout
  | Some cmd ->
    (* First, run mach preprocessing to a temp file *)
    let temp = Filename.temp_file "mach-pp" ".ml" in
    Fun.protect ~finally:(fun () -> try Sys.remove temp with _ -> ())
      (fun () ->
        Out_channel.with_open_text temp (fun oc ->
          In_channel.with_open_text source_path (fun ic ->
            Mach_module.preprocess_source ~source_path oc ic));
        (* Then run external preprocessor *)
        let full_cmd = Printf.sprintf "%s %s" cmd (Filename.quote temp) in
        let code = Sys.command full_cmd in
        if code <> 0 then Mach_error.user_errorf "preprocessor %S failed" cmd)
```

### Step 3: Update build rule generation

In `lib/mach_lib.ml`, modify `configure_ocaml_module`:

**Current code** (lines 51-58):
```ocaml
let configure_ocaml_module b (m : ocaml_module) =
  let src_ext = src_ext_of_kind m.kind in
  let src = Filename.(m.build_dir / m.module_name ^ src_ext) in
  let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
  Ninja.rulef b ~target:src ~deps:[m.ml_path] "%s pp %s > %s" cmd m.ml_path src;
  (* ... *)
```

**New code**:
```ocaml
let configure_ocaml_module b (m : ocaml_module) =
  (* Output is always .ml since mlx-pp transforms MLX to plain OCaml *)
  let src = Filename.(m.build_dir / m.module_name ^ ".ml") in
  let mli = Filename.(m.build_dir / m.module_name ^ ".mli") in
  let pp_flag = match m.kind with ML -> "" | MLX -> " --pp mlx-pp" in
  Ninja.rulef b ~target:src ~deps:[m.ml_path] "%s pp%s %s > %s" cmd pp_flag m.ml_path src;
  (* ... *)
```

### Step 4: Remove `-pp mlx-pp` from compilation commands

In `compile_ocaml_module`, remove the `pp_flag` variable and its usage:

**Current code** (lines 74-96):
```ocaml
let compile_ocaml_module b (m : ocaml_module) =
  let src_ext = src_ext_of_kind m.kind in
  let src = Filename.(m.build_dir / m.module_name ^ src_ext) in
  (* ... *)
  let pp_flag = match m.kind with ML -> "" | MLX -> " -pp mlx-pp" in
  (* ... ocamlc/ocamlopt with pp_flag ... *)
```

**New code**:
```ocaml
let compile_ocaml_module b (m : ocaml_module) =
  (* Always .ml since preprocessing outputs plain OCaml *)
  let src = Filename.(m.build_dir / m.module_name ^ ".ml") in
  (* ... *)
  (* Remove pp_flag entirely - preprocessing already done *)
  (* ... ocamlc/ocamlopt WITHOUT pp_flag ... *)
```

### Step 5: Update CLI binding

In `bin/mach.ml`, update the `pp_cmd` definition:

```ocaml
let pp_cmd =
  let doc = "Preprocess source file to stdout (for use with merlin -pp)" in
  let info = Cmd.info "pp" ~doc ~docs:Manpage.s_none in
  let pp_arg = Arg.(value & opt (some string) None & info ["pp"]
    ~docv:"COMMAND" ~doc:"External preprocessor to run after mach preprocessing") in
  let f source pp_cmd = pp ?pp_cmd source in
  Cmd.v info Term.(const f $ source_arg $ pp_arg)
```

### Step 6: Update mach-lsp integration

In `bin/mach_lsp.ml`, update the merlin directives to include mlx-pp for .mlx files. This requires checking the file extension:

**Current code** (line 69):
```ocaml
let directives =
  `FLG ["-pp"; "mach pp"] :: directives
```

**New code** - need to check file extension and add appropriate -pp flag:
```ocaml
let directives =
  let pp_cmd = match module_kind_of_path source_path with
    | ML -> "mach pp"
    | MLX -> "mach pp --pp mlx-pp"
  in
  `FLG ["-pp"; pp_cmd] :: directives
```

Note: This may require exposing `module_kind_of_path` in `mach_lib.mli` or moving it to a shared location.

## Testing

### Update existing tests

The existing tests in `test/test_pp.t` and `test/test_mlx.t` should continue to pass without modification (behavior is preserved).

### Add new test for `--pp` option

Add a new test in `test/test_pp.t`:

```
Test mach pp with external preprocessor (mlx-pp):

  $ command -v mlx-pp > /dev/null || exit 80

  $ cat > component.mlx << 'EOF'
  > #!/usr/bin/env mach
  > let div ~children () = String.concat ", " children
  > let () = print_endline <div>"Hello"</div>
  > EOF

  $ mach pp --pp mlx-pp component.mlx | head -5
  # 1 "component.mlx"

  let div ~children () = String.concat ", " children
  let () = print_endline ((div ~children:["Hello"] ()))
```

## Summary of Changes

| File | Changes |
|------|---------|
| `lib/mach_lib.ml` | Modify `pp` function to accept optional `pp_cmd` parameter; update `configure_ocaml_module` to use `--pp mlx-pp` for MLX files; update `compile_ocaml_module` to remove `-pp mlx-pp` flag; output preprocessed files always as `.ml` |
| `lib/mach_lib.mli` | Update `pp` signature to accept optional `pp_cmd` parameter |
| `bin/mach.ml` | Add `--pp` option to `pp` subcommand |
| `bin/mach_lsp.ml` | Update merlin `-pp` directive to include `--pp mlx-pp` for MLX files |
| `test/test_pp.t` | Add test for `--pp` option |

## Open Questions

1. **Line directive preservation**: When piping through `mlx-pp`, does it preserve/update the `# 1 "file"` line directive? Need to verify this works correctly for error messages to point to original source locations.

2. **Error handling**: If `mlx-pp` fails, the error message should be clear about what failed and where.

3. **Performance**: Using a temp file is simpler but adds I/O overhead. For the typical use case (small OCaml scripts), this should be negligible. Consider piping directly if performance becomes an issue.
