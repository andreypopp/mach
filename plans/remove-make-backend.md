# Remove Make Build Backend

## Overview

Remove the Make build backend, keeping only Ninja as the sole build system. This simplifies the codebase by eliminating the build backend abstraction layer.

## Files to Delete

1. **`lib/makefile.ml`** - Makefile generation implementation (29 lines)
2. **`lib/makefile.mli`** - Makefile interface (3 lines)
3. **`lib/s.ml`** - Build backend signature (13 lines) - no longer needed with single backend
4. **`test_makefile/`** - Entire directory (env.sh, tests symlink)

## Files to Modify

### 1. `lib/mach_config.ml`

**Changes:**
- Remove `type build_backend = Make | Ninja` (line 8)
- Remove `build_backend_to_string` and `build_backend_of_string` functions (lines 10-14)
- Remove `build_backend` field from `type t` record (line 55)
- Remove `default_build_backend = Make` constant (line 60)
- Simplify `parse_file` to remove `build-backend` handling (unknown keys will error)
- Update `make_config` to not include `build_backend` in returned record (lines 113-122)

### 2. `lib/mach_config.mli`

**Changes:**
- Remove `type build_backend = Make | Ninja` (line 6)
- Remove `build_backend_to_string` and `build_backend_of_string` declarations (lines 8-9)
- Remove `build_backend` field from `type t` (line 26)

### 3. `lib/mach_lib.ml`

**Changes:**
- Remove `type build_backend = Mach_config.build_backend = Make | Ninja` re-export (line 15)
- In `configure_backend` (lines 48-55):
  - Remove `build_backend` local binding
  - Remove first-class module pattern - use `Ninja` module directly
  - Hardcode `module_file = "mach.ninja"` and `root_file = "build.ninja"`
  - Replace all `B.xxx` calls with `Ninja.xxx` calls
- In `configure_exn` (lines 194-209):
  - Remove the `config.build_backend` match for cleanup (lines 194-199) - use Ninja behavior for partial reconfigure (no cleanup, rely on `ninja -t cleandead`)
  - Make the `ninja -t cleandead` call unconditional (remove the match on lines 203-205)
- In `build_exn` (lines 237-239):
  - Remove the match on `config.build_backend` for build command
  - Always use ninja command: `"ninja --quiet"` or `"ninja -v"` based on verbosity

### 4. `lib/ninja.mli`

**Changes:**
- Remove `include S.BUILD` (line 3)
- Inline the signature from `s.ml` directly into this file

### 5. `test_ninja/env.sh`

**Changes:**
- Remove the `Mach` config file creation entirely (the `cat > Mach` block)
- Just set `MACH_HOME` environment variable

### 6. `CLAUDE.md`

**Changes:**
- Remove references to Make backend throughout:
  - Line 29: Change "shows make/ninja output" to "shows ninja output"
  - Line 52: Remove `build-backend` config key documentation entirely
  - Line 73: Remove `lib/makefile.ml` from architecture list
  - Line 126: Remove Make backend build files documentation
  - Lines 153-154: Remove makefile.ml and makefile.mli from file structure
  - Lines 161-163: Remove test_makefile directory documentation
- Update line 74 (`lib/ninja.ml`) description - it's now the only build backend

## Implementation Order

1. **Delete `lib/makefile.ml` and `lib/makefile.mli`**
2. **Delete `test_makefile/` directory**
3. **Update `lib/ninja.mli`** - inline S.BUILD signature
4. **Delete `lib/s.ml`**
5. **Update `lib/mach_config.mli`** - remove build_backend type and field
6. **Update `lib/mach_config.ml`** - remove build_backend type, functions, field; simplify parse_file
7. **Update `lib/mach_lib.ml`** - simplify to use Ninja directly, remove all build backend matching
8. **Update `test_ninja/env.sh`** - remove Mach config file creation
9. **Update `CLAUDE.md`** - remove Make references
10. **Run `dune build` to verify compilation**
11. **Run `dune test` to verify all tests pass**

## Config File Handling

Remove `build-backend` as a recognized config key entirely. If a user has `build-backend "..."` in their `Mach` file, it will error as an unknown key.

## Testing

After implementation:
1. Run `dune build` - should compile without errors
2. Run `dune test test_ninja/tests/` - all ninja backend tests should pass
