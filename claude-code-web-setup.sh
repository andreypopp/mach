#!/usr/bin/env bash
if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
  exit 0
fi
# setup
mkdir -p ~/bin
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
# install opam
curl -fsSL https://github.com/ocaml/opam/releases/download/2.5.0/opam-2.5.0-x86_64-linux -o ~/bin/opam
chmod +x ~/bin/opam
# initialize opam
opam init --disable-sandboxing --yes
# init project
cat .envrc >> ~/.bashrc
make init
