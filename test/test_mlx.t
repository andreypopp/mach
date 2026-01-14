Isolate mach config to a test dir:
  $ . ../env.sh

Check if mlx-pp is available, skip if not:
  $ command -v mlx-pp > /dev/null || exit 80

Test simple .mlx file:
  $ cat << 'EOF' > component.mlx
  > let div ~children () = String.concat ", " children
  > let () = print_endline <div>"Hello, MLX!"</div>
  > EOF

  $ mach run ./component.mlx
  Hello, MLX!

Test .mlx depending on .ml:
  $ cat << 'EOF' > helper.ml
  > let greet () = print_endline "Hello from ML"
  > EOF

  $ cat << 'EOF' > app.mlx
  > #require "./helper.ml"
  > let div ~children () = String.concat ", " children
  > let () = print_endline <div>"Starting greeting:"</div>
  > let () = Helper.greet ()
  > EOF

  $ mach run ./app.mlx
  Starting greeting:
  Hello from ML

Test .ml depending on .mlx:
  $ cat << 'EOF' > widget.mlx
  > let div ~children () = String.concat ", " children
  > let render () = print_endline <div>"Widget rendered"</div>
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./widget.mlx"
  > let () = Widget.render ()
  > EOF

  $ mach run ./main.ml
  Widget rendered
