# mach

A tiny build system for OCaml

## `mach run SCRIPT`

Create a file `utils.ml`:
```ocaml
let greet name =
  Printf.sprintf "Hello, %s!" name
```

Then `script.ml`:
```ocaml
#!/usr/bin/env mach run
#require "./utils.ml"  (* makes Utils module available *)

let () = print_endline (Utils.greet "world")
```

Then:
```bash
chmod +x script.ml
./script.ml
```

On first execution, `mach` will build the script and its dependencies, caching
the build artifacts in `$MACH_HOME/_mach/build/` (`$MACH_HOME` defaults to `~/.local/state/mach`).
Subsequent executions will reuse the cached artifacts unless the source files have changed.

## `mach build SCRIPT`

The command `mach build` builds a script and its dependencies but doesn't
execute it.

## `mach build -w SCRIPT` / `mach build --watch SCRIPT`

If the `-w` or `--watch` flag is provided, `mach build` watches the source files and
rebuilds on changes. Requires the `watchexec` program to be available.

## `mach-lsp`

`mach-lsp` starts a language server for OCaml that works with `mach` scripts
and libraries. The `ocamllsp` program must be available.

## Consuming installed (opam/ocamlfind) libraries

It is possible to depend on libraries available through `ocamlfind` (usually
installed with `opam`). This is done through the `#require` directive which
mentions the library name:
```ocaml
#require "lwt"  (* Makes Lwt module available *)
```

## Planned Features

The following features are not yet implemented:

### Libraries

Define and build OCaml libraries with `mach`. A library would be a directory
containing a `Machlib` file and OCaml source files, consumed via
`#require "./path/to/mylib"`.

### PPX Preprocessing

Use ppx preprocessors via the `#ppx "ppx_deriving.show"` directive.
