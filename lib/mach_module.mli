(** Modules which are build with mach are .ml files with mach directives. *)

open! Mach_std

(** Result of resolving a require directive *)
type require =
  | Require of string with_loc        (** path to .ml/.mlx file *)
  | Require_lib of string with_loc    (** path to a library directory (a directory with Machlib file) *)
  | Require_extlib of extlib with_loc (** ocamlfind library name *)

and extlib = { name : string; version : string }

val equal_require : require -> require -> bool
(** Compare two requires for equality, ignoring source location *)

val resolve_require : Mach_config.t -> source_path:string -> line:int -> string -> require
(** Resolve a require.
    Handles both module files (.ml/.mlx) and library directories (with Machlib). *)

type t = {
  path_ml : string;                   (** path to .ml/.mlx file *)
  path_ml_stat : file_stat;
  path_mli : string option;           (** path to .mli/.mli file, if any *)
  path_mli_stat : file_stat option;
  requires : require list lazy_t;     (** resolved requires *)
  kind : kind;                        (** kind of source file *)
}

and kind = ML | MLX

val of_path : Mach_config.t -> string -> (t, Mach_error.t) result

val of_path_exn : Mach_config.t -> string -> t

val kind_of_path_ml : string -> kind

val preprocess_source : source_path:string -> out_channel -> in_channel -> unit
(** Preprocess source file, stripping directives while preserving line numbers *)

val path_mli : string -> string option
(** Given a .ml/.mlx path, return the corresponding .mli/.mli path if it exists. *)

val cmx : Mach_config.t -> t -> string

val extlibs : t -> string list
(** List of external libraries required by this module. *)
