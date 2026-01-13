type verbose = Quiet | Verbose | Very_verbose | Very_very_verbose

let verbose = ref Quiet

let log_at level fmt =
  Printf.ksprintf (fun msg -> if !verbose >= level then Printf.eprintf "%s\n%!" msg) fmt

let log_verbose fmt = log_at Verbose fmt
let log_very_verbose fmt = log_at Very_verbose fmt
