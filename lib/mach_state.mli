(** Mach state keep stats of a dependency graph of modules. *)

open! Mach_std

type t

type mach_unit =
  | Unit_module of Mach_module.t
  | Unit_lib of Mach_library.t

type unit_with_status = {
  unit: mach_unit;
  unit_state: t;
  unit_status : [`Fresh | `Fresh_but_update_state | `Need_configure ];
}

val crawl : Mach_config.t -> target_path:string -> unit_with_status list
(** Crawl the dependency graph starting from the given target path.
    Returns a list modules/libs to build, in a link order. *)

val write : Mach_config.t -> t -> unit
(** Write state to a file. *)
