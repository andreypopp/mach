(** Mach state keep stats of a dependency graph of modules. *)

open! Mach_std

type t

type 'a with_state = { 
  unit: 'a;
  state: t;
  need_configure: bool;
}

val crawl : Mach_config.t -> target_path:string -> Mach_module.t with_state list * Mach_library.t with_state list

val write : Mach_config.t -> t -> unit
(** Write state to a file. *)
