type verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

val verbose : verbose ref

val log_verbose : ('a, unit, string, unit) format4 -> 'a
val log_very_verbose : ('a, unit, string, unit) format4 -> 'a
