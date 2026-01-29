type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

(** Build target type *)
type target =
  | Target_executable of string  (** path to module which defines an executable *)
  | Target_library of string     (** path to library directory *)

val resolve_target : Mach_config.t -> string -> target
(** Resolve a path to a target type. Raises [Mach_error.Mach_user_error] if
    the path is an external library. *)

val target_path : target -> string
(** Get the path from a target *)

val pp : source_path:string -> in_channel -> out_channel -> unit

val configure : Mach_config.t -> target -> (bool * Mach_module.t list * Mach_library.t list, Mach_error.t) result

val build : Mach_config.t -> target -> (string * bool * Mach_module.t list * Mach_library.t list, Mach_error.t) result

module Build : sig

  module Build_file_format : sig
    type t = stanza list
    and stanza =
      | Rule of {
          targets: string array; (** absolute paths of targets rule produces *)
          deps: string array; (** absolute paths of dependencies rule requires *)
          commands: string array; (** a list of shell commands to execute to build the targets *)
        }
      | Rule_dyndep of {
          target: string; (** absolute path of a target containing dyndep *)
          deps: string array; (** absolute paths of dependencies rule requires *)
          commands: string array; (** a list of shell commands to execute to build the target *)
        }

    val of_string : string -> t
    val to_string : t -> string
    val of_file : string -> t
    val to_file : string -> t -> unit
  end

  module Dyndep_file_format : sig
    type t = dyndep list
    and dyndep = {
      target: string; (** absolute path of target that lists additional dependencies *)
      deps: string array; (** absolute paths of additional dependencies *)
    }

    val of_string : string -> t
    val to_string : dyndep list -> string

    val of_file : string -> t
    val to_file : string -> dyndep list -> unit
  end

  type t
  val create : unit -> t
  val configure : t -> Build_file_format.t -> unit
  val build : t -> target_path:string -> unit
end
