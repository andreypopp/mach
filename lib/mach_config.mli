(** Mach configuration discovery and parsing *)

open! Mach_std

(** Build backend type *)
type build_backend = Make | Ninja

val build_backend_to_string : build_backend -> string
val build_backend_of_string : string -> build_backend

(** Detected toolchain versions *)
type toolchain = {
  ocaml_version : string;
  ocamlfind_version : string option;
  ocamlfind_libs : SS.t;  (** empty if ocamlfind not installed *)
}

(** Mach configuration *)
type t = {
  home : string;
  build_backend : build_backend;
  mach_executable_path : string;
  toolchain : toolchain;
}

(** Get the current configuration.
    Resolution order:
    1. $MACH_HOME env var if set
    2. Walk up from cwd to find Mach file
    3. Fall back to $XDG_STATE_HOME/mach (or ~/.local/state/mach) *)
val get : unit -> (t, Mach_error.t) result

(** Get build directory for a script path *)
val build_dir_of : t -> string -> string
