#!/usr/bin/env bash
# Gázóra leolvasás minden képre a megadott könyvtárban
# Használat:  ./run_all.sh dir [modell]
# DIR: a könyvtár, amelyben a képeket keresni kell
set -euo pipefail

DIR="${1:?Használat: $0 dir [modell]}"
MODEL="${2:-qwen3-vl:2b-instruct}"
for IMG in "$DIR"/*.{jpg,jpeg,png}; do
    echo "Processing $IMG with model $MODEL"
    ./run.sh "$IMG" "$MODEL"
done