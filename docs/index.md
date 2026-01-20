Mach is a tiny build system for OCaml scripts. It compiles code on first run,
subsequent runs perform incremental compilation, if needed.

Mach supports dependencies between scripts and on external libraries (usually
installed with [opam][]) through `#require` directives.

Usage is as simple as creating an `.ml` file:
```ocaml
#require "./utils"
#require "lwt"
let () =
  Lwt_main.run (Utils.greet "Mach")
```

and then running:
```sh
$ mach run main.ml
```

[opam]: https://opam.ocaml.org/

Below is the documentation for installation and usage:
<toc>

## INSTALLATION

Mach is distributed as a single `mach.ml` source file. It requires OCaml
toolchain and Ninja build system to be installed.

### Installation through homebrew

Install using [homebrew][] (macOS/Linux):

```sh
$ brew tap mach-build/tap
$ brew install mach --HEAD
```

Apart from `mach` executable this install bash/zsh completion scripts and a man
page.

[homebrew]: https://brew.sh/

### Manual installation

Requires OCaml compiler installed:
```sh
$ wget https://raw.githubusercontent.com/andreypopp/mach/refs/heads/main/_dist/mach.ml
$ ocamlopt -I +unix -o mach unix.cmxa mach.ml
```

## USAGE

Create `hello.ml` file:
```ocaml
let () =
  print_endline "Hello, Mach!"
```

Run it with `mach run` command:
```sh
$ mach run hello.ml
Hello, Mach!
```

One can also put `#!/usr/bin/env mach run --` shebang line at the top of the file:
```ocaml
#!/usr/bin/env mach run --
let () =
  print_endline "Hello, Mach!"
```
Make it executable and run:
```sh
$ chmod +x hello.ml
$ ./hello.ml
Hello, Mach!
```

### Declaring dependencies between scripts

Scripts can reference other scripts using `#require` directive. File extensions
are omitted — Mach automatically resolves `.ml` and `.mlx` files:
```ocaml
#require "./utils"
let () =
  Utils.greet "Mach"
```

Where `utils.ml` contains:
```ocaml
let greet name =
  Printf.printf "Hello, %s!\n" name
```
Run it:
```sh
$ mach run main.ml
Hello, Mach!
```

### Declaring dependencies on libraries

You can also depend on external libraries:
```ocaml
#require "lwt"
let () =
  let task =
    Lwt_io.printf "Hello from Lwt!\n"
  in
  Lwt_main.run task
```
Run it:
```sh
$ mach run lwt_example.ml
Hello from Lwt!
```

External libraries require `ocamlfind` to be installed.

### Building code without running

To compile without running, use `mach build` command:
```sh
$ mach build hello.ml
```
This is useful to get compilation errors without executing the code.

### Watch mode

Both `mach build` and `mach run` commands support `--watch` mode that starts
watching source code for changes and rebuilds (and reruns in case of `mach
run`) the code on each change:
```sh
$ mach run --watch hello.ml
```

Note that [watchexec] tool is required for this feature to work. Install it
using your package manager (e.g. `brew install watchexec` on macOS).

[watchexec]: https://github.com/watchexec/watchexec

### Editor integration / LSP

Install `mach-lsp` package for LSP support:
```sh
$ opam install mach-lsp
```

Configure your editor to use `mach-lsp` as the language server for OCaml files.

### Support for .mlx syntax dialect

Mach supports [.mlx][] syntax dialect out of the box:
```ocaml
let div ~children () =
  String.concat ", " children
let () =
  print_endline <div>"Hello, MLX!"</div>
```

Run it:
```sh
$ mach run example.mlx
```

[.mlx]: https://github.com/ocaml-mlx/mlx

## CONTRIBUTING

The source code is at [andreypopp/mach][]. Please open issues (and pull
requests) for any bugs and/or feature requests.

[andreypopp/mach]: https://github.com/andreypopp/mach
