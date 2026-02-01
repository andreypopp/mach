Test depending on lwt.unix library (requires C stubs linking).

Create a script that uses lwt.unix:
  $ cat << 'EOF' > main.ml
  > #require "lwt.unix"
  > let () =
  >   let promise = Lwt.return 42 in
  >   let result = Lwt_main.run promise in
  >   Printf.printf "Result: %d\n" result
  > EOF

Run the script:
  $ mach run ./main.ml
  Result: 42
