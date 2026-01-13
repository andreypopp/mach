# Plan: Environment Configuration

## Summary

Refactor how mach discovers its home directory and build backend configuration:

1. `$MACH_HOME` defaults to `$XDG_STATE_HOME/mach` (or `~/.local/state/mach`) if not set
2. Build artifacts go to `$MACH_HOME/_mach/build/` instead of `$MACH_HOME/build/`
3. Remove `--build-backend` CLI option; instead read from `$MACH_HOME/Mach` config file
4. If `$MACH_HOME` is not set, search for `Mach` file upward from current directory (like git finds `.git`)

## Current State

### In `lib/mach_lib.ml`:

```ocaml
let config_dir =
  lazy (
    match Sys.getenv_opt "MACH_HOME" with
    | Some dir -> dir
    | None -> Filename.(Sys.getenv "HOME" / ".cache" / "mach"))
let config_dir () = Lazy.force config_dir

let build_dir_of script_path =
  let normalized = String.split_on_char '/' script_path |> String.concat "__" in
  Filename.(config_dir () / "build" / normalized)
```

### In `bin/mach.ml`:

```ocaml
let build_backend_arg =
  let doc = "Build backend to use: 'make' (default) or 'ninja'. \
             Can also be set via MACH_BUILD_BACKEND environment variable." in
  let env = Cmd.Env.info "MACH_BUILD_BACKEND" in
  Arg.(value & opt (enum ["make", Make; "ninja", Ninja]) Make & info ["build-backend"] ~env ~doc)
```

### Tests

- `test_makefile/env.sh` and `test_ninja/env.sh` set `MACH_HOME` and `MACH_BUILD_BACKEND`
- Tests use `MACH_HOME=$PWD/mach` pattern

## Implementation Steps

### Step 1: Create `Mach_config` submodule in `lib/mach_lib.ml`

Config file format uses `<key> "<value>"` syntax:

```
build-backend "ninja"
```

```ocaml
(* --- Mach config --- *)

module Mach_config : sig
  type t = {
    home: string;
    build_backend: build_backend;
  }

  val get : unit -> t
  val build_dir_of : t -> string -> string
end = struct
  type t = {
    home: string;
    build_backend: build_backend;
  }

  let default_build_backend = Make

  let parse_file path =
    In_channel.with_open_text path (fun ic ->
      let rec loop ~build_backend line_num =
        match In_channel.input_line ic with
        | None -> ~build_backend
        | Some line ->
          let line = String.trim line in
          if line = "" || String.starts_with ~prefix:"#" line then
            loop ~build_backend (line_num + 1)
          else
            match Scanf.sscanf_opt line "%s %S" (fun k v -> k, v) with
            | None ->
              user_error (sprintf "%s:%d: malformed line" path line_num)
            | Some (key, value) ->
              match key with
              | "build-backend" ->
                let build_backend =
                  try build_backend_of_string value
                  with Failure msg -> user_error (sprintf "%s:%d: %s" path line_num msg)
                in
                loop ~build_backend (line_num + 1)
              | _ ->
                user_error (sprintf "%s:%d: unknown key: %s" path line_num key)
      in
      loop ~build_backend:default_build_backend 1)

  let find_mach_config () =
    let rec search dir =
      let mach_path = Filename.(dir / "Mach") in
      if Sys.file_exists mach_path then Some (dir, mach_path)
      else
        let parent = Filename.dirname dir in
        if parent = dir then None
        else search parent
    in
    search (Sys.getcwd ())

  let config =
    lazy (
      match Sys.getenv_opt "MACH_HOME" with
      | Some home ->
        let mach_path = Filename.(home / "Mach") in
        let build_backend =
          if Sys.file_exists mach_path then
            let ~build_backend = parse_file mach_path in build_backend
          else default_build_backend
        in
        { home; build_backend }
      | None ->
        match find_mach_config () with
        | Some (home, mach_path) ->
          let ~build_backend = parse_file mach_path in
          { home; build_backend }
        | None ->
          let home = match Sys.getenv_opt "XDG_STATE_HOME" with
            | Some xdg -> Filename.(xdg / "mach")
            | None -> Filename.(Sys.getenv "HOME" / ".local" / "state" / "mach")
          in
          { home; build_backend = default_build_backend })

  let get () = Lazy.force config

  let build_dir_of config script_path =
    let normalized = String.split_on_char '/' script_path |> String.concat "__" in
    Filename.(config.home / "_mach" / "build" / normalized)
end
```

### Step 2: Remove old `config_dir` and `build_dir_of`

Delete:
```ocaml
let config_dir =
  lazy (
    match Sys.getenv_opt "MACH_HOME" with
    | Some dir -> dir
    | None -> Filename.(Sys.getenv "HOME" / ".cache" / "mach"))
let config_dir () = Lazy.force config_dir

let build_dir_of script_path =
  let normalized = String.split_on_char '/' script_path |> String.concat "__" in
  Filename.(config_dir () / "build" / normalized)
```

### Step 3: Update all functions to take config as argument

Functions that currently use `config_dir()` or `build_dir_of` need updating:

**`Mach_state` module:**
- `exe_path` needs config
- `collect_exn` needs config
- Update signature to take `config: Mach_config.t`

**`configure_exn` and `configure`:**
- Take config as first argument
- Pass to `Mach_state` functions

**`build_exn` and `build`:**
- Take config as first argument
- Pass to `configure_exn`

**`watch_exn` and `watch`:**
- Take config as first argument
- Pass to `build_exn`

### Step 4: Update `bin/mach.ml`

Remove `build_backend_arg` and update all commands to get config at start:

```ocaml
let run verbose script_path args =
  Mach_lib.verbose := verbose;
  let config = Mach_lib.Mach_config.get () in
  let ~state, ~reconfigured:_ = build config script_path |> or_exit in
  let exe_path = Mach_state.exe_path config state in
  ...

let build_cmd =
  let f verbose watch script_path =
    Mach_lib.verbose := verbose;
    let config = Mach_lib.Mach_config.get () in
    if watch then Mach_lib.watch config script_path |> or_exit
    else build config script_path |> or_exit |> ignore
  in
  ...

let configure_cmd =
  let f path =
    let config = Mach_lib.Mach_config.get () in
    configure config path |> or_exit |> ignore
  in
  ...
```

### Step 5: Update test environment files

**`test_makefile/env.sh`:**
```bash
export MACH_HOME="$PWD"
cat > Mach << 'EOF'
build-backend "make"
EOF
```

**`test_ninja/env.sh`:**
```bash
export MACH_HOME="$PWD"
cat > Mach << 'EOF'
build-backend "ninja"
EOF
```

### Step 6: Update tests that check build directory paths

Tests check paths like `mach/build/*main.ml/`. With `MACH_HOME="$PWD"`, paths become `_mach/build/*main.ml/`.

Update `test/test_build_dir_auto.t`:
- Change `mach/build/` to `_mach/build/`

Update `test/test_simple.t`, `test/test_ninja.t`, etc.:
- Change any `mach/build/` references to `_mach/build/`

### Step 7: Update CLAUDE.md documentation

- Remove `--build-backend` CLI option docs
- Document `Mach` config file format: `build-backend "ninja"`
- Document `$MACH_HOME` defaults to `$XDG_STATE_HOME/mach`
- Document `_mach/build/` subdirectory structure
- Document Mach file discovery (walks up from cwd)

## API Changes

### Before

```ocaml
(* mach_lib.mli *)
val config_dir : unit -> string
val build_dir_of : string -> string
val configure : ?build_backend:build_backend -> string -> ...
val build : ?build_backend:build_backend -> string -> ...
val watch : ?build_backend:build_backend -> string -> ...
```

### After

```ocaml
(* mach_lib.mli *)
module Mach_config : sig
  type t = { home: string; build_backend: build_backend }
  val get : unit -> t
  val build_dir_of : t -> string -> string
end

val configure : Mach_config.t -> string -> ...
val build : Mach_config.t -> string -> ...
val watch : Mach_config.t -> string -> ...
```

## Code Changes Summary

### `lib/mach_lib.ml`

1. Move `build_backend` type before config module (already there)
2. Add `Mach_config` submodule with config parsing and discovery
3. Remove old `config_dir` and `build_dir_of`
4. Update `Mach_state.exe_path` to take config
5. Update all build functions to take config as first arg
6. Remove `?build_backend` optional arg from functions

### `bin/mach.ml`

1. Remove `build_backend_arg` definition
2. Remove `$ build_backend_arg` from all Term definitions
3. Update `run`, `build_cmd`, `configure_cmd` to call `Mach_config.get()`
4. Pass config to all library functions

### `test_makefile/env.sh`

```bash
export MACH_HOME="$PWD"
cat > Mach << 'EOF'
build-backend "make"
EOF
```

### `test_ninja/env.sh`

```bash
export MACH_HOME="$PWD"
cat > Mach << 'EOF'
build-backend "ninja"
EOF
```

### Test files

Update path references from `mach/build/` to `_mach/build/`

## Verification

1. `dune build` should succeed
2. `dune test` should pass all tests (in both test_makefile/ and test_ninja/ directories)
3. Manual test: verify Mach file discovery works by creating a project with `Mach` file

## Risk Assessment

**Medium risk**:
- Changes fundamental path resolution logic affecting all operations
- Changes API signatures (functions now require config argument)
- Tests will catch most issues since they cover various scenarios
- User errors raised for malformed config will surface immediately
