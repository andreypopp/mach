(** Mach configuration discovery and parsing *)

(** Build backend type *)
type build_backend = Make | Ninja

val string_of_build_backend : build_backend -> string
val build_backend_of_string : string -> build_backend

type error = [`User_error of string]

(** Mach configuration *)
type t = {
  home : string;
  build_backend : build_backend;
}

(** Get the current configuration.
    Resolution order:
    1. $MACH_HOME env var if set
    2. Walk up from cwd to find Mach file
    3. Fall back to $XDG_STATE_HOME/mach (or ~/.local/state/mach) *)
val get : unit -> (t, error) result

(** Get build directory for a script path *)
val build_dir_of : t -> string -> string
