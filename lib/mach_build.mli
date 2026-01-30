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

module Rules : sig
  type t

  val create : unit -> t
  val to_list : t -> Build_file_format.t

  val rule :
    t ->
    target:string ->
    deps:string list ->
    string list ->
    unit

  val rulef :
    t ->
    target:string ->
    deps:string list ->
    ('a, unit, string, unit) format4 ->
    'a

  val rule_dyndep :
    t ->
    target:string ->
    deps:string list ->
    string list ->
    unit
end

type t
val create : unit -> t
val configure : t -> Build_file_format.t -> unit
val build : t -> target_path:string -> parallelism:int -> unit
