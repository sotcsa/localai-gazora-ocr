#!/usr/bin/env bash
# Gázóra leolvasás minden képre a megadott könyvtárban
# Használat:  ./run_all.sh dir [modell]
# DIR: a könyvtár, amelyben a képeket keresni kell
# Képenként menti az eredményt (OUT_DIR/<kép>.json) és a naplót (OUT_DIR/<kép>.log),
# a végén táblázatban kiírja az óraállásokat, és CSV-be is menti (OUT_DIR/osszesito.csv).
#   OUT_DIR - az eredmények könyvtára (alapértelmezett: eredmenyek)
set -euo pipefail

DIR="${1:?Használat: $0 dir [modell]}"
MODEL="${2:-qwen3-vl:2b-instruct}"
OUT_DIR="${OUT_DIR:-eredmenyek}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT_DIR"

shopt -s nullglob nocaseglob
IMAGES=("$DIR"/*.{jpg,jpeg,png})
shopt -u nullglob nocaseglob
[ ${#IMAGES[@]} -gt 0 ] || { echo "Nincs kép itt: $DIR" >&2; exit 1; }

CSV="$OUT_DIR/osszesito.csv"
echo "kep;oraallas_m3;confidence;ido_mp;statusz" > "$CSV"
ROWS=()
n=0
for IMG in "${IMAGES[@]}"; do
  n=$((n + 1))
  name=$(basename "$IMG")
  json="$OUT_DIR/${name%.*}.json"
  logf="$OUT_DIR/${name%.*}.log"
  echo "[$n/${#IMAGES[@]}] $name ($MODEL)" >&2
  t0=$(date +%s)
  if "$SCRIPT_DIR/run.sh" "$IMG" "$MODEL" > "$json" 2> "$logf"; then
    status="OK"
  else
    status="HIBA"
  fi
  secs=$(( $(date +%s) - t0 ))

  reading="-"; conf="-"
  if [ "$status" = OK ] && jq -e . "$json" >/dev/null 2>&1; then
    if [ "$(jq -r '.is_gas_meter' "$json")" = true ]; then
      reading="$(jq -r '"\(.integer_part),\(.decimal_part)"' "$json")"
      conf="$(jq -r '.confidence // "-"' "$json")"
    else
      status="nem gázóra"
    fi
  elif [ "$status" = OK ]; then
    status="HIBA"
  fi
  [ "$status" = HIBA ] && echo "  hiba, napló: $logf" >&2
  echo "  -> $reading ($secs mp)" >&2

  echo "$name;$reading;$conf;$secs;$status" >> "$CSV"
  ROWS+=("$name|$reading|$conf|$secs|$status")
done

# Összesítő táblázat. A printf bájtokat számol, az ékezetes szövegnél elcsúszna: karakterre igazítunk.
pad() { printf '%s%*s' "$1" $(( $2 - ${#1} > 0 ? $2 - ${#1} : 0 )) ''; }
row() { echo "$(pad "$1" "$w")  $(pad "$2" 12)  $(pad "$3" 5)  $(pad "$4" 6)  $5"; }
w=3
for r in "${ROWS[@]}"; do name="${r%%|*}"; [ ${#name} -gt $w ] && w=${#name}; done
echo
row "Kép" "Óraállás m³" "Bizt." "Idő mp" "Státusz"
row "$(printf '%*s' "$w" '' | tr ' ' -)" "------------" "-----" "------" "-------"
for r in "${ROWS[@]}"; do
  IFS='|' read -r name reading conf secs status <<< "$r"
  row "$name" "$reading" "$conf" "$secs" "$status"
done
echo
echo "Eredmények: $OUT_DIR/ (képenként .json és .log), összesítő: $CSV"
