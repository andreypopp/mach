(** Mach state keep stats of a dependency graph of modules. *)

type error = [ `User_error of string ]

type file_stat = { mtime : int; size : int }

type entry = {
  ml_path : string;
  mli_path : string option;
  ml_stat : file_stat;
  mli_stat : file_stat option;
  requires : string list;  (** absolute paths to required modules *)
  libs : string list;  (** ocamlfind library names *)
}

(** State metadata for detecting configuration changes *)
type header = {
  build_backend : Mach_config.build_backend;
  mach_executable_path : string;
}

type t = { header : header; root : entry; entries : entry list }

(** Read state from a file, returns None if file doesn't exist or is invalid *)
val read : string -> t option

(** Write state to a file *)
val write : string -> t -> unit

(** Check if state needs reconfiguration due to file changes or config changes *)
val needs_reconfigure : Mach_config.t -> t -> bool

(** Collect dependency state starting from an entry point module *)
val collect : Mach_config.t -> string -> (t, error) result

(** Get the executable path for a state *)
val exe_path : Mach_config.t -> t -> string

(** Get all unique source directories from entries *)
val source_dirs : t -> string list

(** Get all unique ocamlfind library names from entries *)
val all_libs : t -> string list

(** Extract #require directives from a source file *)
val extract_requires : string -> (requires:string list * libs:string list, error) result

