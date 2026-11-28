#!/usr/bin/env bash
# Build the booklet in <name>/ into <directory>/<name>.pdf.
# Typst, its packages and the fonts come from the repository flake:
# `nix build .#booklets` runs this for every booklet, and
# `nix develop .#booklets` gives a shell to run it in by hand.
set -euo pipefail
name=$1
mkdir -p "$2"
out=$(cd "$2" && pwd)
cd "$(dirname "$0")"
typst compile --root . --ignore-system-fonts "$name/main.typ" "$out/$name.pdf"
