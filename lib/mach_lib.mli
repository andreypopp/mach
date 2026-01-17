type verbose = Mach_log.verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

val pp : string -> unit

val configure : Mach_config.t -> string -> ((state:Mach_state.t * reconfigured:bool), Mach_error.t) result

val build : Mach_config.t -> string -> ((state:Mach_state.t * reconfigured:bool), Mach_error.t) result
