type error = [`User_error of string]

type verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

val verbose : verbose ref

val extract_requires : string -> (requires:string list * libs:string list, error) result

module Mach_state : sig
  type file_stat = { mtime : int; size : int }

  type entry = {
    ml_path : string;
    mli_path : string option;
    ml_stat : file_stat;
    mli_stat : file_stat option;
    requires : string list;
    libs : string list;
  }

  type metadata = { build_backend : Mach_config.build_backend; mach_path : string }

  type t = { metadata : metadata; root : entry; entries : entry list }

  val read : string -> t option

  val collect : build_backend:Mach_config.build_backend -> mach_path:string -> string -> (t, error) result

  val exe_path : Mach_config.t -> t -> string (** exe_path *)

  val source_dirs : t -> string list (** list of source dirs *)

  val all_libs : t -> string list (** all unique libs from all entries *)
end

val pp : string -> unit

val configure : Mach_config.t -> string -> ((state:Mach_state.t * reconfigured:bool), error) result

val build : Mach_config.t -> string -> ((state:Mach_state.t * reconfigured:bool), error) result

val watch : Mach_config.t -> string -> (unit, error) result
