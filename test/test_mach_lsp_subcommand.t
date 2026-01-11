Test mach lsp subcommand
  $ . ../env.sh

Test that mach lsp suggests installing mach-lsp when not in PATH:
  $ MACH_BIN=$(which mach) && PATH="" $MACH_BIN lsp 2>&1
  mach-lsp not found in PATH.
  Install it with: opam install mach-lsp
  [1]

Test that mach lsp --help shows the subcommand documentation:
  $ mach lsp --help
  NAME
         mach-lsp - Start OCaml LSP server with mach support (requires
         mach-lsp)
  
  SYNOPSIS
         mach lsp [OPTION]… [ARGS]…
  
  ARGUMENTS
         ARGS
             Arguments to pass to mach-lsp
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
  EXIT STATUS
         mach lsp exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         mach(1)
  

