# mach

mach is an OCaml runtime tailored for scripting.

## `mach run SCRIPT`

Define a script in a file `utils.ml`:
```ocaml
let greet name =
  Printf.sprintf "Hello, %s!" name
```

then `script.ml`:
```ocaml
#!/usr/bin/env mach
#require "./utils.ml"  (* makes Utils module available *)

let () = print_endline (Utils.greet "world")
```

Then:
```bash
chmod +x script.ml
./script.ml
```

On first execution, `mach` will build the script and its dependencies, caching
the build artifacts in the `~/.config/mach/build/` directory. Subsequent executions
will reuse the cached artifacts unless the source files have changed.

## `mach build SCRIPT`

The command `mach build` builds a script and its dependencies but doesn't
execute it.

## `mach build --watch SCRIPT`

If the `--watch` flag is provided, `mach build` watches the source files and
rebuilds on changes. Requires `watchexec` program to be available.

## `mach-lsp`

`mach-lsp` starts a language server for OCaml that works with `mach` scripts
and libraries. The `ocamllsp` program must be available.

## TODO: Libraries

It is also possible to define and build OCaml libraries with `mach`.

A library is a directory containing a `Machlib` file and an assorted set of
OCaml source files. All source files in the directory are part of the library.
The entry point module is derived from the directory name.

Consuming libraries is done through the `#require ".."` directive (as above)
where the path is the path to the library directory:

    #require "./path/to/mylib"  (* Makes Mylib module available *)

## TODO: Libraries from ocamlfind/opam

It is possible to depend on libraries available through `ocamlfind` (usually
installed with `opam`):
```ocaml
#require "lwt"  (* Makes Lwt module available *)
```

## TODO: Preprocessing with PPX

It is possible to use ppx preprocessors on the source files:
```
#ppx "ppx_deriving.show"  (* Use ppx_deriving's show preprocessor *)
```

At the moment only ppx available through `ocamlfind` (usually installed with
`opam`) are supported.
