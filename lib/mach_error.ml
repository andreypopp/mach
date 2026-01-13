exception Mach_user_error of string

let user_errorf fmt = Printf.ksprintf (fun msg -> raise (Mach_user_error msg)) fmt

type t = [`User_error of string]
