module Build_file_format : sig
  type t
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

(** A command line fragment, along with its dependencies and targets. *)
module Cmd : sig
  type t = {
    command : string;
    deps : string list;
    targets : string list;
  }

  val v : ?deps:string list -> ?targets:string list -> string -> t

  val concat : t list -> t
  (** Concatenate commands by joining them with " " *)
end

(** A rule builder *)
module Rule : sig
  type t

  val create : unit -> t
  (** Create an empty rule builder *)

  val to_list : t -> Build_file_format.t
  (** Convert the rule builder to a list of build rules *)

  val rule :
    t ->
    targets:string list ->
    deps:string list ->
    string list ->
    unit

  val rule_dyndep :
    t ->
    target:string ->
    deps:string list ->
    string list ->
    unit

  val rule_of_commands : ?deps:string list -> t -> Cmd.t list -> unit
end

type t
val create : unit -> t
val configure : t -> Build_file_format.t -> unit
val build : t -> target_path:string -> parallelism:int -> unit
