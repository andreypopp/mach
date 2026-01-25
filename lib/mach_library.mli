(** This module represents a mach library. *)

open! Mach_std

type t = {
  path : string;                               (* absolute path to library directory *)
  modules : lib_module list Lazy.t;            (* modules in the library *)
  requires : Mach_module.require list Lazy.t;  (* resolved requires *)
}

and lib_module = {
  file_ml : string;         (** relative filename *)
  file_mli : string option; (** relative filename, if exists *)
}

val of_path : Mach_config.t -> string -> t
(** Load library from a path. *)

val configure_library : Mach_config.t -> t -> unit
(** Configure build for a library. *)

val cmxa : Mach_config.t -> t -> string
(** Path to library's .cmxa file *)

val equal_lib_module : lib_module -> lib_module -> bool
