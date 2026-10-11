#!/usr/bin/env bash
# Gázóra leolvasás minden képre a megadott könyvtárban
# Használat:  ./run_all.sh dir [modell]
# DIR: a könyvtár, amelyben a képeket keresni kell
# Képenként menti az eredményt (OUT_DIR/<kép>.json) és a naplót (OUT_DIR/<kép>.log),
# a végén táblázatban kiírja az óraállásokat és az időstatisztikát.
# Fájlok az OUT_DIR-ben:
#   osszesito.csv   - az aktuális futás sorai (minden futás felülírja)
#   naplo.csv       - minden futás sorai egymás után fűzve (ezt érdemes Google Táblázatba importálni)
#   statisztika.txt - az aktuális futás statisztikája
# A CSV pontosvesszővel tagolt, tizedesvesszős (magyar Excel / Google Táblázat így olvassa számként).
#   OUT_DIR - az eredmények könyvtára (alapértelmezett: eredmenyek)
set -euo pipefail

DIR="${1:-$HOME/Downloads/drive-download-20261009T063617Z-1-001}"
MODEL="${2:-qwen3.5:4b}"
OUT_DIR="${OUT_DIR:-eredmenyek}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT_DIR"

shopt -s nullglob nocaseglob
IMAGES=("$DIR"/*.{jpg,jpeg,png})
shopt -u nullglob nocaseglob
[ ${#IMAGES[@]} -gt 0 ] || { echo "Nincs kép itt: $DIR" >&2; exit 1; }

CSV="$OUT_DIR/osszesito.csv"
HIST="$OUT_DIR/naplo.csv"
STATS="$OUT_DIR/statisztika.txt"
HEADER="futas;kep;oraallas;m3;confidence;ido_mp;statusz;modell"
echo "$HEADER" > "$CSV"
[ -s "$HIST" ] || echo "$HEADER" > "$HIST"
RUN_TS=$(date '+%Y-%m-%d %H:%M:%S')
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
hu() { echo "${1//./,}"; }   # tizedespont -> tizedesvessző
RUN_T0=$(now)
ROWS=()
n=0
for IMG in "${IMAGES[@]}"; do
  n=$((n + 1))
  name=$(basename "$IMG")
  json="$OUT_DIR/${name%.*}.json"
  logf="$OUT_DIR/${name%.*}.log"
  echo "[$n/${#IMAGES[@]}] $name ($MODEL)" >&2
  t0=$(now)
  if "$SCRIPT_DIR/run.sh" "$IMG" "$MODEL" > "$json" 2> "$logf"; then
    status="OK"
  else
    status="HIBA"
  fi
  secs=$(echo "$(now) $t0" | awk '{printf "%.1f", $1 - $2}')

  reading="-"; conf="-"; m3=""
  if [ "$status" = OK ] && jq -e . "$json" >/dev/null 2>&1; then
    if [ "$(jq -r '.is_gas_meter' "$json")" = true ]; then
      reading="$(jq -r '"\(.integer_part),\(.decimal_part)"' "$json")"
      conf="$(jq -r '.confidence // "-"' "$json")"
      m3="$(jq -r '"\(.integer_part).\(.decimal_part)" | tonumber? // ""' "$json")"
    else
      status="nem gázóra"
    fi
  elif [ "$status" = OK ]; then
    status="HIBA"
  fi
  [ "$status" = HIBA ] && echo "  hiba, napló: $logf" >&2
  echo "  -> $reading ($secs mp)" >&2

  # Az óraállás szövegként (vezető nullákkal) és számként (m3) is bekerül.
  line="$RUN_TS;$name;$reading;$(hu "$m3");$(hu "$conf");$(hu "$secs");$status;$MODEL"
  echo "$line" >> "$CSV"
  echo "$line" >> "$HIST"
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

# Statisztika: darabszámok és futásidők (összes, átlag, medián, min, max).
echo
TOTAL=$(echo "$(now) $RUN_T0" | awk '{printf "%.1f", $1 - $2}')
{
  echo "Futás: $RUN_TS, modell: $MODEL, könyvtár: $DIR"
  printf '%s\n' "${ROWS[@]}" | sort -t'|' -k4,4n | awk -F'|' -v total="$TOTAL" '
    function mmss(s) { return sprintf("%d:%02d", int(s / 60), int(s) % 60) }
    { t[NR] = $4; nm[NR] = $1; sum += $4
      if ($5 == "OK") ok++; else if ($5 == "HIBA") err++; else other++ }
    END {
      med = (NR % 2) ? t[(NR + 1) / 2] : (t[NR / 2] + t[NR / 2 + 1]) / 2
      printf "Képek: %d (OK: %d, nem gázóra: %d, hiba: %d)\n", NR, ok, other, err
      printf "Teljes futásidő: %.1f mp (%s)\n", total, mmss(total)
      printf "Képenként: átlag %.1f mp, medián %.1f mp\n", sum / NR, med
      printf "Leggyorsabb: %.1f mp (%s)\n", t[1], nm[1]
      printf "Leglassabb:  %.1f mp (%s)\n", t[NR], nm[NR]
    }'
} | tee "$STATS"
echo
echo "Eredmények: $OUT_DIR/ (képenként .json és .log)"
echo "Összesítő: $CSV, minden futás: $HIST, statisztika: $STATS"
