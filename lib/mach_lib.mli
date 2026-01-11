type error = [`User_error of string]

type verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

val verbose : verbose ref

type build_backend = Make | Ninja

val build_dir_of : string -> string

module Mach_state : sig
  type file_stat = { mtime : int; size : int }

  type entry = {
    ml_path : string;
    mli_path : string option;
    ml_stat : file_stat;
    mli_stat : file_stat option;
    requires : string list;
  }

  type t = { root : entry; entries : entry list }

  val read : string -> t option

  val collect : string -> (t, error) result

  val exe_path : t -> string (** exe_path *)

  val source_dirs : t -> string list (** list of source dirs *)
end

val pp : string -> unit

val configure : ?build_backend:build_backend -> string -> ((state:Mach_state.t * reconfigured:bool), error) result

val build : ?build_backend:build_backend -> string -> ((state:Mach_state.t * reconfigured:bool), error) result

val watch : ?build_backend:build_backend -> string -> (unit, error) result
