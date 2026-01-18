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
  > #require "./helper"
  > let div ~children () = String.concat ", " children
  > let () = print_endline <div>"Starting greeting:"</div>
  > let () = Helper.greet ()
  > EOF

  $ mach run ./app.mlx
  Starting greeting:
  Hello from ML

Test .ml depending on .mlx (tests .mlx fallback when no .ml exists):
  $ cat << 'EOF' > widget.mlx
  > let div ~children () = String.concat ", " children
  > let render () = print_endline <div>"Widget rendered"</div>
  > EOF

  $ cat << 'EOF' > main.ml
  > #require "./widget"
  > let () = Widget.render ()
  > EOF

  $ mach run ./main.ml
  Widget rendered

Test .mlx-only resolution explicitly (ensure .ml is not present):
  $ rm -f mlxonly.ml
  $ cat << 'EOF' > mlxonly.mlx
  > let div ~children () = String.concat ", " children
  > let message () = <div>"MLX only module"</div>
  > EOF

  $ cat << 'EOF' > main_mlxonly.ml
  > #require "./mlxonly"
  > let () = print_endline (Mlxonly.message ())
  > EOF

  $ mach run ./main_mlxonly.ml
  MLX only module

Test .ml takes priority when both .ml and .mlx exist:
  $ cat << 'EOF' > ambiguous.ml
  > let source () = "from .ml file"
  > EOF

  $ cat << 'EOF' > ambiguous.mlx
  > let div ~children () = String.concat ", " children
  > let source () = <div>"from .mlx file"</div>
  > EOF

  $ cat << 'EOF' > main_ambiguous.ml
  > #require "./ambiguous"
  > let () = print_endline (Ambiguous.source ())
  > EOF

  $ mach run ./main_ambiguous.ml
  from .ml file
