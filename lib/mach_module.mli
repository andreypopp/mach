(** Modules which are build with mach are .ml files with mach directives. This
    module helps processing those. *)

open! Mach_std

(** Extract #require directives from a source file *)
val extract_requires : string -> (requires:string with_loc list * libs:string with_loc list, Mach_error.t) result

(** Extract #require directives from a source file, raises on error *)
val extract_requires_exn : string -> requires:string with_loc list * libs:string with_loc list

(** Preprocess source file, stripping directives while preserving line numbers *)
val preprocess_source : source_path:string -> out_channel -> in_channel -> unit
