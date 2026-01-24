(* Ninja file generator API *)

type t

val create : unit -> t
val contents : t -> string

val var : t -> string -> string -> unit
val subninja : t -> string -> unit
val rule : t -> target:string -> deps:string list -> ?dyndep:string -> string list -> unit
val rulef : t -> target:string -> deps:string list -> ('a, unit, string, unit) format4 -> 'a
val rule_phony : t -> target:string -> deps:string list -> unit
