(* s.ml - Module signatures for mach *)

module type BUILD = sig
  type t
  val create : unit -> t
  val contents : t -> string

  val include_ : t -> string -> unit
  val rule : t -> target:string -> deps:string list -> string list -> unit
  val rulef : t -> target:string -> deps:string list -> ('a, unit, string, unit) format4 -> 'a
  val rule_phony : t -> target:string -> deps:string list -> unit
end
