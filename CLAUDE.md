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
```

### Configuration

mach discovers configuration via:
1. `$MACH_HOME` environment variable (if set)
2. Walk up from cwd to find a `Mach` config file (like git finds `.git`)
3. Fall back to `$XDG_STATE_HOME/mach` (default: `~/.local/state/mach`)

When `MACH_HOME` is set or discovered, mach looks for a `Mach` file there to read settings.

**Mach config file format** (`$MACH_HOME/Mach`):
```
build-backend "ninja"
```

Supported keys:
- `build-backend` - Build system to use: `"make"` (default) or `"ninja"`

### mach-lsp

LSP support for editors. Wraps `ocamllsp` with mach-aware merlin configuration:

```bash
mach-lsp              # starts ocamllsp with mach support
mach-lsp ocaml-merlin # merlin server mode (called by ocamllsp)
```

## Architecture

Split across multiple files:
- `bin/mach.ml` (~65 lines) - CLI entry point
- `lib/mach_config.ml` (~95 lines) - configuration discovery and parsing
- `lib/mach_lib.ml` (~500 lines) - core implementation
- `bin/mach_lsp.ml` (~90 lines) - LSP/merlin support

The library uses `(wrapped false)` so modules are accessed directly (e.g., `Mach_config`, `Mach_lib`).

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
- **Location**: `$MACH_HOME/_mach/build/<normalized-path>/`
- **Normalized path**: Source path with `/` replaced by `__`
- **State file**: `Mach.state` tracks file mtimes/sizes for cache invalidation
- **Build files**: `Makefile` (root), `mach.mk` (per-module), `includes.args`, `all_objects.args`

## Code Style

- **Avoid O(n) lookups in loops**: Don't use `List.mem` or `List.assoc` for membership checks inside loops - this creates O(n^2) complexity. Use `Hashtbl` instead for O(1) lookups.

## File Structure

```
bin/
  mach.ml        -- CLI entry point
  mach_lsp.ml    -- LSP/merlin support
  dune
lib/
  mach_config.ml  -- configuration discovery and parsing
  mach_config.mli -- config interface
  mach_lib.ml     -- core implementation
  mach_lib.mli    -- core interface
  dune
test/
  test_*.t     -- cram test case files, add test to this dir
test_makefile/ -- tests for Makefile build backend
  env.sh       -- environment setup for tests (sets MACH_HOME, creates Mach config)
  tests/       -- symlink to ../test/
test_ninja/    -- tests for ninja build backend
  env.sh       -- environment setup for tests (sets MACH_HOME, creates Mach config)
  tests/       -- symlink to ../test/
plans/         -- implementation plans
```
