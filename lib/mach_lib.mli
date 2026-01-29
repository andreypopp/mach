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
  type rule = {
    targets: string array; (** absolute paths of targets rule produces *)
    deps: string array; (** absolute paths of dependencies rule requires *)
    commands: string array; (** a list of shell commands to execute to build the targets *)
  }

  type build = {
    rules: rule list;
  }

  val build_of_string : string -> build
  val build_of_file : string -> build

  val build : target_path:string -> build -> unit
end
