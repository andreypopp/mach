Test type hiding via .mli (abstract types).

  $ . ../env.sh

  $ cat << 'EOF' > counter.ml
  > type t = int
  > let create () = 0
  > let incr t = t + 1
  > let value t = t
  > EOF

  $ cat << 'EOF' > counter.mli
  > type t
  > val create : unit -> t
  > val incr : t -> t
  > val value : t -> int
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./counter"
  > let () =
  >   let c = Counter.create () in
  >   let c = Counter.incr c in
  >   let c = Counter.incr c in
  >   Printf.printf "count = %d\n" (Counter.value c)
  > EOF

  $ mach run ./main.ml
  count = 2
