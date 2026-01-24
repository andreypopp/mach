(** Mach state keep stats of a dependency graph of modules. *)

open! Mach_std

type t

val read : string -> t option
(** Read state from a file, returns None if file doesn't exist or is invalid. *)

val write : string -> t -> unit
(** Write state to a file. *)

(** Reason for reconfiguration *)
type reconfigure_reason =
  | Env_changed  (** Mach path or toolchain version changed *)
  | Paths_changed of SS.t  (** Set of ml_path that need reconfiguration *)

val check_reconfigure_exn : Mach_config.t -> t -> reconfigure_reason option
(** Check if state needs reconfiguration, and if so, what kind. *)

val collect : Mach_config.t -> string -> (t, Mach_error.t) result
(** Collect dependency state starting from an entry point module. *)

val collect_exn : Mach_config.t -> string -> t
(** Same as collect but raises on error. *)

val source_dirs : t -> string list
(** All source directories. *)

val modules : t -> Mach_module.t list
(** All modules. *)

val libs : t -> Mach_library.t list
(** All libraries. *)

val extlibs : t -> string list
(** All ocamlfind library names from entries *)
