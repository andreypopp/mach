# TODO

## Implement proper preprocessing pipeline

Right now we preprocess each module via `ocamlc -pp ...` command. We want to
implement preprocessing via build system so we can feed preprocessed output to
`ocamldep` (not needed now but later) and then `ocamlc` without doing
preprocessing twice.

I think `mach-pp` command can be such driver:

    $ mach pp <src> build_dir/<src.pp.ml> --pp 'mlx-pp'

and then compile `build_dir/<src.pp.ml>` with `ocamlc` without `-pp` flag.

## Implement support for libraries

We consider a directory with `Machlib` file as a library.

It means that all the modules found in that directory (excluding subdirectories) are part of that library.

We compile a library into `.cmxa` file.

When a script depends on a library, we link against that `.cmxa` file.

## Implement ppx support

## Support passing -H hidden includes args when compiling

## [DONE] Remove make build backend 

We are going to remove make build backend and keep only ninja. Please remove any make-related code.

## [DONE] Optimise reconfiguration: only reconfigure affected modules

We need to improve Mach_state.needs_reconfiguration to return list of modules
that need to be reconfigured.

We will then drop build dirs of only those modules that need to be reconfigured.

Modules which depend on them will be rebuilt automatically by Makefile as their
.cmo targets depend on their dependencies' .cmi files.

## [DONE] Watch mode doesn't start if initial build fails

## [DONE] Support .mlx

There's this OCaml dialect called `.mlx` which adds support for jsx syntax.

The command `mlx-pp` preprocesses `.mlx` files to `.ml` files. And I think we
can use `-pp` flag of `ocamlopt` to preprocess `.mlx` files on the fly.

We want to be able to build `.mlx` files with `mach` tool.

Additionally for LSP/merlin there's `ocamlmerlin-mlx` tool that adds support for
`.mlx` files. We need to configure it as a READER in `mach-lsp` tool for `.mlx` files.

## [DONE] Info about ocaml and ocamlfind versions

On startup we should check which ocaml and ocamlfind versions are installed,
store them in config.

We should also persist them in Mach.state header and on reconfiguration check
if they have changed.

Additionally, no reconfiguration we should check if ocamlfind is installed when
we found some modules reference libs.

## [DONE] Error output overhaul

Right now when we fail, we print lots of noise from make/ninja.

Let's generate Makefiles/Ninja files by making sure each command invocation is
piped through a special formatter which prefixes each line with the special
token `>>>`.

Then when we run make/ninja, we parse its output line by line. For lines
starting with `>>>`, we strip the prefix and print them to stderr. For other
lines we ignore them.

The special formatter is `mach format-cmd-output` subcommand which reads from stdin
and writes to stdout, prefixing each line with `>>>`.

## [DONE] Environment configuration

Tasks:
- make `$MACH_HOME` default to `$XDG_STATE_HOME/mach` if not set
- make dir with builds go to `$MACH_HOME/_mach/build/`
- remove `--build-dir` option and instead allow to have `$MACH_HOME/Mach` file which can set `--build-backend` option
- in absence of `$MACH_HOME` env var, find `Mach` in the current directory or any parent directory (like git)

## [DONE] More reconfiguration fixes

We need to also reconfigure when
1. build backend changes
2. own mach path changes (see we have code already which detects the curren path, move it to helper)

need to store this as part of Mach.state

    build_backend <make|ninja>
    mach_path /absolute/path/to/mach

## [DONE] Implement depdending on ocamlfind libraries

We want to support depending on ocamlfind libraries.

If user writes

    #require "lwt";;

where the string is not a path (i.e. it doesn't start with `/` or `./` or
`../`), we treat it as an ocamlfind library.

We collect all such requires.

Then we produce `lib-includes.args` file in build dir using command:

    ocamlfind query -i-format -recursive LIB1 LIB2 ...

Then when compiling we pass `-args lib-includes.args` to `ocamlc`.

Same for linking, we produce `lib-objects.args` file using:

    ocamlfind query -a-format -recursive -predicates native LIB1 LIB2 ...

Then when linking we pass `-args lib-objects.args` to `ocamlopt`.

Add test which uses `cmdliner` package.

## [DONE] Switch to compiling native executables

For `.cmi` we still can use `ocamlc` (for speed) but instead of `.cmo` we
should compile to `.cmx` and then link to native executable.

## [DONE] Unify `mach preprocess` and `mach pp`

Keep on `mach pp`. We use it now for merlin but for build we have `mach preprocess`

So the idea is for build we call `mach pp` twice for .ml and .mli (if present).

## [DONE] Fix shell completion for `mach` command

Right now completions don't work correctly for script arguments. Need to
configure terms to have completion of type `file`. See `Cmdliner` docs for
that.

## [DONE] Add `mach lsp` subcommand

**decided not to implement**

The new subcommand `mach lsp` should call into `mach-lsp` executable (if
avaialble), if not - it should suggest to install `mach-lsp` opam package.

## [DONE] Overhaul error reporting

There are cases where we just use `failwith` for error reporting. Need to
analyze these and for cases where the error is a user error — we should report
them nicely.

I think within `mach_lib.ml` we can use an exception `Mach_user_error of
string` but functions exposed outside should catch those and convert them to
``('a, `Msg string) result`` values.

Then `bin/mach.ml` should handle those errors and print them nicely to stderr
and exit with code 1.

## [DONE] watch mode

Implement `--watch` option for `mach build SCRIPT.ml` command.

When `--watch` is given, we want to watch all files in the dependency graph. We are going to use `watchexec` tool for that:

    $ watchexec --no-meta --emit-events-to=stdio --only-emit-events -W @/tmp/watchlist.txt

research `watchexec --manual` for more info (what other options we might use?).

The gist, when `--watch` is given:
- we check if `watchexec` is installed, if not we error out asking user to install it
- on start we get mach state
- we start watchexec process watching all the dirs (`-W @/tmp/watchlist.txt`) where source files are located
- we read watchexec output line by line
- on each event (file change) we check if the file is in the dependency graph
- if yes, we re-build the script (re-configure if needed, then build)

## [DONE] Optimize re-configuration step

Right now we re-configure (i.e. re-generate Makefile and mach.mk files) on each
change to any file in the dependency graph.

But we actually need to do that only when:
- a new file is added to the dependency graph (deps or .mli)
- a file is removed from the dependency graph (deps or .mli)

In addition to that we need to re-configure only the modules that are affected by
the change. For example if we add a new dependency to `modA.ml`, we need to
re-configure `modA.ml` and all modules that depend on it (transitively).

At the same time .mli addition/removal changes only affect the module itself,
not its dependents.

I think we should replace Mach_state.is_fresh with a more elaborate check which
returns what modules need to be re-configured.

## [DONE] Implement ninja build backend

Right now we generate and build with Makefile. We want to implement ninja build backend as well.

First let's refactor `Makefile` module to move OCaml specific bits outside of
it so `Makefile` module is generic and only concernts itself with generating
Makefile syntax.

Next let's move `Makefile` module into `lib/makefile.ml` file (also create
`.mli` as well) first. I think we want to keep

Now we can create `Ninja` module in `lib/ninja.ml` file (with `.mli` as well) that would
implement similar functionality as `Makefile`. I'd even suggest to share same interface.

After that we can add a `--build-backend` option to `mach` command that would
accept either `make` or `ninja` (default to `make` for backward compatibility).

## [DONE] Implement `mach-lsp` command

The new command `mach-lsp` should start a `ocamllsp`.

The catch is that we need to pass configuration to `ocamllsp`. Afaik `ocamllsp`
calls `dune ocaml-merlin` to start a server which is then used by `ocamllsp` to
query info about source files.

I think we need to implement a similar server in `mach-lsp` that would respond to
merlin queries. The invocation will be `mach-lsp ocaml-merlin`.

So we start `ocamllsp` with `OCAML_MERLIN_BIN=mach-lsp` env variable. This will instruct `ocamllsp` to use `mach-lsp ocaml-merlin` as the merlin server.

Then we need to implement `mach-lsp ocaml-merlin` command that would respond to
merlin queries. Merlin uses _opam/lib/merlin-lib/dot_protocol/ lib (see .ml and
.mli there) for implementing such servers. We can use this library to implement
our own merlin server.

So we need to create a separate executable `mach-lsp` that would implement
merlin server.

## [DONE] Make sure error reporting correctly reports source file paths

When there is a compilation error in a dependency, make sure the error
reporting shows the original source file path, not the build dir path.

Need to test this and fix if not working.

## [DONE] Test removing/adding files to dep graph

We need to exercise adding/removing files to the dependency graph and see that
it works as expected.

Tests added in separate files:
- `test/test_dep_add.t` - Adding a new dependency
- `test/test_dep_remove.t` - Removing a dependency
- `test/test_dep_modify.t` - Modifying a dependency
- `test/test_dep_transitive_add.t` - Adding transitive dependency
- `test/test_dep_transitive_remove.t` - Removing transitive dependency
- `test/test_dep_replace.t` - Replacing a dependency

Note: Tests require `sleep 1` between first run and modifications due to
filesystem timestamp resolution (Make uses second-precision mtime comparisons).

## [DONE] Support .mli files

We need to support .mli files for modules.

If .mli is present we compile it first to .cmi, then compile .ml to .cmo using
that .cmi (use `-cmi-file` flag to pass .cmi path when compiling .cmo).

So that means we need to copy .mli to build dir as well. And we somehow (decide
how better) need to remove .mli from build dir when it is removed from source
dir.

Also need to test that adding/removing .mli files works as expected.

## [DONE] Reorganize build

Currently we offload much of the build logic into a generated Makefile. This
becomes too complex and hard to add features to.

Instead we want to move more logic into `mach` itself. We'll still keep using
Makefile for executation of actual build but configuration and dependency
resolution should be done in `mach`.

Proposed flow, on each invocation of `mach SCRIPT.ml`:
- `mach` reads the `SCRIPT.ml`, extracts require directives, then do so recursively for each dependency
- `mach` generates `mach.mk` for each module in the dependency graph
- `mach` generates `Makefile` for the root script which includes all `mach.mk`
  files of dependencies and has a target for linking the final executable
- `mach` invokes `make` to build the script and execute it

Because reading and parsing modules is done in `mach` on each invocation, we
need to optimize it for speed. I propose we produce a file with mstat of each
file visited, and on subsequent invocations we skip reading/parsing files that
have not changed:
```~/.config/mach/build/.../Mach.state
/absolute/path/to/mod.ml <mtime of mod.ml> <size of mod.ml>
  requires /absolute/path/to/dependency1.ml
  requires /absolute/path/to/dependency2.ml
...
```
If any file has changed, we re-generate `mach.mk` for all modules (this is done
for simplicity, we can optimize it later if needed). And produce new
`Mach.state`.

## [DONE] Refactoring: separate require extraction and preprocessing

Right now we preprocess and extract require directives in a single step but do it twice:
- once during `configure` step to extract require directives
- once during build step to preprocess the source file

Instead we can separate these two steps:
- extract requires directives only (no preprocessing) during `configure` step
- preprocess only (no require extraction) during build step

We can also embed includes.args content into mach.mk files instead of generating it during preprocessing.

## [DONE] Refactoring: change syntax for require directives

Right now we use `[%%require "mod.ml"]` syntax for require directives and use
OCaml parser to extract them.

Instead I propose we use a simpler syntax which doesn't require OCaml parser:

    #!/usr/bin/env mach run
    #require "mod.ml"

This way we can extract require directives via simple line-by-line parsing
without needing full OCaml parser. We also require that directives appear at
the top of the file before any OCaml code. Empty lines are allowed though.

We still go line by line over the whole file to extract all require directives
but error on ones which come after OCaml code.

We also allow `;;` after require directives, out of backward compatibility with
toplevel syntax. But we just ignore them, they have no meaning.

## [DONE] Add `mach build` command w/o --watch

Let's add `mach build SCRIPT` subcommand which just builds the script without executing it.

## [DONE] Cleanup: remove --build-dir option

We don't need it as we can use $XDG_CONFIG_HOME to control the root mach dir.

## [DONE] Refactoring: target for generating deps' mach.mk

Right now we are eagerly generating `mach.mk` files for all dependencies.

Instead, let's add a target in `Makefile` for generating `mach.mk` files of immediate dependencies.

The idea is when running we don't want to recursively traverse the entire
dependency tree, we only want to find immediate dependencies.

## [DONE] Refactoring: getting rid of objects.args

Right now we generate `objects.args` file that contains list of `.cmo` files of immediate dependencies + current module.

Instead let's define `MACH_OBJS` variable in `Makefile`, empty initially.

Then for each immediate dependency we `include` its `mach.mk` file, which appends current module to `MACH_OBJS` variable.

Then for linking we produce `all_objects.args` file with content of `$(MACH_OBJS)` variable.

## [DONE] Refactoring: modularize Makefile

Right now we generate a single `Makefile` for building the script and all its dependencies.

Instead, let's do the following:
- for each ocaml module (script or dependency) generate `mach.mk` file in its build directory
- the `mach.mk` file contains targets for configuring and compiling this module only
- then `mach.mk` file includes `mach.mk` files of its immediate dependencies
- finally the root script's `Makefile` includes its own `mach.mk` and then has a target for linking the final executable

## [DONE] Refactoring: move includes.args generation / preprocessing to Makefile

Right now we generate `includes.args` file in mach before generating `Makefile`.

Instead, let's add a subcommand `mach configure <src-mod.ml>` which would:
- parse `<src-mod.ml>` for require directives
- preprocess `<src-mod.ml>` to remove require directives and output `<build-mod.ml>` to build directory
- generate `includes.args` file in the build directory (with `-I` lines for each immediate dependency)
- generate `objects.args` file in the build directory (with `.cmo` lines for each immediate dependency)

Then we update `Makefile` generation to add a new target like this:
```Makefile
<build-mod.ml>: <src-mod.ml>
    mach configure <src-mod.ml>
includes.args: <build-mod.ml>
objects.args: <build-mod.ml>
```

Now for compile we'd need to depend on `includes.args` for corresponding .cmo.

For linking we'd need to merge all `objects.args` files from all dependencies. Can use a separate target:
```Makefile
all_objects.args: $(DEPS_ALL_OBJECTS_ARGS)
    awk '!seen[$0]++' $(DEPS_ALL_OBJECTS_ARGS) > all_objects.args
```
Then link target would depend on `all_objects.args` and use them as `-args all_objects.args`.

## [DONE] Feature: build with Makefile

Now we want to change how we build the script and its dependencies.

Instead of invoking `ocamlc`, we are going to generate a `Makefile` in the build directory of a script.

The `Makefile` should have targets for each dependency and the script itself. That's it, a single `Makefile` builds all.

We should still keep the current layout, e.g. dependencies and script are built in their corresponding build directories. It's just the commands are executed via from a single `Makefile` of the root script.

## [DONE] Refactoring: builds depenencies in their respective build directories

Right now we copy and build dependencies in the store directory. Instead, we
want to build each dependencies in their respective store directory, like we do for the script.

## [DONE] Feature: non-temp build directory

Right now we make build dir in a temp directory that is deleted after the script
finishes. Instead we would want to derive build directory from the script path and put it into 
`~/.config/mach/build/<normalized script path>`.

The `<normalized script path>` can be derived from the script path by replacing `/` with `__` (double underscore).

If script path already exists we keep it instead of failing.

## [DONE] Add test: test shebang line works

script like this should work:

```ocaml
#!/usr/bin/env mach
print_endline "Hello, world!"
```

## [DONE] Optimisation: fuse require extraction and preprocessing into a single step

We can fuse require extraction and preprocessing into a single step. Also use
`Ast_mapper` so we "preprocess" require directives on any module level.

## [DONE] Optimisation: do not copy .cmi to build dir

Now we copy .cmi from store to build dir.
Instead, we can reference paths directly from store via `-I`.
But such command iine can be long, we can use `-args ARGSFILE` instead to pass
such `-I` arguments via a file. So I suggest we create `includes.args` file in build dir
with all `-I /path/to/store` lines.

## [DONE] New option: --build-dir DIR

If option `--build-dir DIR` is given, use `DIR` as the build directory instead
of a temporary directory. We are going to use thsi for debugging purposes.

## [DONE] New subcommand: mach deps SCRIPT

A new subcommand `mach deps SCRIPT` that prints all dependencies of the given `SCRIPT`:

    $ mach deps my_script.ml
    /absolute/path/to/dependency1.ml <sha256 of dependency1.ml>
    ...

## [DONE] Cache compiled artefacts

Let's cache compiled artefacts to speed up subsequent builds.

Use `~/.config/mach/store/<sha256 of mod.ml>` for a `mod.ml` module. Means we
need to copy sources there. Then do compilation within that directory. So all
`.cmo` and `.cmi` are there.

For each dependency once we resolve it, we check if it is in the store first.
