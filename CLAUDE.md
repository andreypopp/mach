# CLAUDE.md

## Project Overview

**mach** is an OCaml scripting runtime that automatically handles dependencies declared via `#require "..."` directives.

## Build & Test

```bash
dune build # builds the mach executable
dune test # builds and runs tests, no need to run `dune build` first
dune promote # promote test outputs if we see it changed and it's expected
dune test test_ninja/tests/test_build.t # can also run individual tests
```

## Testing

Tests are in `test/` as cram tests (`.t` files). Follow existing examples, only
add cram (`.t`) tests.

If you need to test something, create a new cram test `.t` file in `test/`.

### CLI Options

```bash
mach run script.ml [args...] # run script
mach run --verbose script.ml # verbose mode (logs make/ocamlc commands)

mach build script.ml # build without executing
mach configure script.ml # generate build configuration
mach pp script.ml # preprocess source file to stdout (for merlin and build)

Control build directory location via XDG_CONFIG_HOME
```bash
XDG_CONFIG_HOME=/custom/path mach run script.ml # build artifacts go to /custom/path/mach/build/<normalized-path>/
```

### mach-lsp

LSP support for editors. Wraps `ocamllsp` with mach-aware merlin configuration:

```bash
mach-lsp              # starts ocamllsp with mach support
mach-lsp ocaml-merlin # merlin server mode (called by ocamllsp)
```

## Architecture

Split across multiple files:
- `bin/mach.ml` (~65 lines) - CLI entry point
- `lib/mach_lib.ml` (~330 lines) - core implementation
- `bin/mach_lsp.ml` (~90 lines) - LSP/merlin support

### Code Sections (lib/mach_lib.ml)

The code is organized with comment headers:
- `(* --- Utilities --- *)` - Path helpers, file I/O
- `(* --- Parsing and preprocessing --- *)` - Line-by-line parsing for `#require` directives
- `(* --- State cache --- *)` - Dependency state caching (Mach_state module)
- `(* --- Makefile generation --- *)` - Build system generation (Makefile module)
- `(* --- PP (for merlin and build) --- *)` - Preprocessor support (used by both merlin and build)
- `(* --- Configure --- *)` - Build configuration generation
- `(* --- Build --- *)` - Build execution via Make

### Pipeline

1. **Configure** - Check `Mach.state` freshness; if stale, collect dependencies via DFS and generate per-module `mach.mk` files
2. **Preprocessing** - Replace shebang and `#require` lines with empty lines (preserves line numbers via `# 1 "path"` directive)
3. **Build** - Run Make which handles compilation order and caching
4. **Execution** - `Unix.execv` the resulting binary

### Build Directories

- Each module (script and dependencies) has its own build directory
- **Location**: `~/.config/mach/build/<normalized-path>/`
- **Normalized path**: Source path with `/` replaced by `__`
- **State file**: `Mach.state` tracks file mtimes/sizes for cache invalidation
- **Build files**: `Makefile` (root), `mach.mk` (per-module), `includes.args`, `all_objects.args`

## File Structure

```
bin/
  mach.ml      -- CLI entry point
  mach_lsp.ml  -- LSP/merlin support
  dune
lib/
  mach_lib.ml  -- core implementation
  dune
test/
  test_*.t     -- cram test case files, add test to this dir
test_makefile/ -- tests for Makefile build backend
  env.sh       -- environment setup for tests
  tests/       -- symlink to ../test/
test_ninja/    -- tests for ninja build backend
  env.sh       -- environment setup for tests
  tests/       -- symlink to ../test/
plans/         -- implementation plans
```
