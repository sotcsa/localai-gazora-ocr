#!/usr/bin/env bash
# Gázóra leolvasás lokálisan, Ollamával, ugyanazzal a prompttal, mint az Apps Scriptben.
# Használat:  ./ollama_teszt.sh kep.jpg [modell]
# Előtte:     ollama pull qwen3-vl:2b-instruct
# Az "-instruct" változat kell: a sima qwen3-vl:2b gondolkodó (thinking) változat, ami
# a think:false ellenére is sokáig gondolkodik, és nem marad helye a válasznak.
# Kell hozzá: curl, jq, base64 (macOS-en a kicsinyítéshez a beépített sips)
#
# A lépések naplója a stderr-re megy ([HH:MM:SS] előtaggal), az eredmény JSON a stdout-ra.
# A nyers Ollama-választ elmenti: ollama_valasz.json (a script mellé, az aktuális mappába).
set -euo pipefail

IMG="${1:?Használat: $0 kep.jpg [modell]}"
MODEL="${2:-qwen3-vl:2b-instruct}"
HOST="${OLLAMA_HOST_URL:-http://localhost:11434}"
NUM_CTX="${NUM_CTX:-4096}"
MAX_PX="${MAX_PX:-1280}"
RAW_OUT="ollama_valasz.json"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "HIBA: $*"; exit 1; }
size() { du -h "$1" | cut -f1; }

PROMPT='This is a photo of a household gas meter with a mechanical drum counter (m³).
Read the counter value.
- integer_part: the digits before the decimal point, usually on a black/dark background (typically 5 digits). Keep leading zeros.
- decimal_part: the digits after the decimal point, usually on a red background or after a comma (typically 3 digits). Empty string if not visible.
- If a drum is halfway between two digits, use the smaller digit (the one rolling out), except 9→0 where you use 9.
- Ignore serial numbers, year of manufacture, Qmax and other printed labels.
- confidence: 0..1, how sure you are that every digit is correct.
- If the image is not a gas meter or the counter is unreadable, set is_gas_meter accordingly and leave the parts empty.
- note: a short remark in Hungarian only if something is unusual (blur, glare, partly hidden digits), otherwise empty.'

SCHEMA='{
  "type": "object",
  "properties": {
    "is_gas_meter": {"type": "boolean"},
    "integer_part": {"type": "string"},
    "decimal_part": {"type": "string"},
    "confidence":   {"type": "number"},
    "note":         {"type": "string"}
  },
  "required": ["is_gas_meter", "integer_part", "decimal_part", "confidence"]
}'

# 1. Előfeltételek
log "Kép: $IMG ($( [ -f "$IMG" ] && size "$IMG" || echo 'NEM TALÁLHATÓ'))"
[ -f "$IMG" ] || die "a képfájl nem létezik"
for c in curl jq base64; do command -v "$c" >/dev/null || die "hiányzik: $c"; done

# 2. Ollama szerver és modell
VER=$(curl -s --max-time 5 "$HOST/api/version" | jq -r '.version // empty' || true)
[ -n "$VER" ] || die "az Ollama nem érhető el itt: $HOST (fut az Ollama app / 'ollama serve'?)"
log "Ollama szerver OK, verzió: $VER"
curl -s "$HOST/api/tags" | jq -e --arg m "$MODEL" '.models[] | select(.name == $m or .model == $m)' >/dev/null \
  || die "a(z) $MODEL modell nincs letöltve. Futtasd: ollama pull $MODEL"
log "Modell megvan: $MODEL (num_ctx=$NUM_CTX)"

# 3. Kicsinyítés
TMP=$(mktemp); SMALL="$(mktemp).jpg"; REQ=$(mktemp); trap 'rm -f "$TMP" "$SMALL" "$REQ"' EXIT
if command -v sips >/dev/null; then
  sips -Z "$MAX_PX" -s format jpeg "$IMG" --out "$SMALL" >/dev/null
  DIM=$(sips -g pixelWidth -g pixelHeight "$SMALL" | awk '/pixel/{print $2}' | paste -sd x -)
  log "Kicsinyítve: ${DIM} px, $(size "$SMALL")"
  IMG="$SMALL"
else
  log "sips nem elérhető, eredeti méretben küldöm"
fi

# 4. Kérés összeállítása
base64 < "$IMG" | tr -d '\n' > "$TMP"
# think:false – a qwen3-vl "gondolkodó" modell; gondolkodással a válasz a 'thinking' mezőbe
# kerülhet, a 'response' pedig üres maradhat (valószínűleg ezért nem írt ki semmit).
jq -n --arg model "$MODEL" --arg prompt "$PROMPT" --rawfile img "$TMP" --argjson schema "$SCHEMA" \
  --argjson ctx "$NUM_CTX" \
  '{model: $model, prompt: $prompt, images: [$img], format: $schema, stream: false, think: false,
    options: {temperature: 0, num_ctx: $ctx, num_predict: 300}}' > "$REQ"
log "Kérés mérete: $(size "$REQ"). Küldés... (az első futásnál a modell betöltése is eltarthat egy ideig)"

# 5. Hívás
START=$(date +%s)
HTTP=$(curl -s -o "$RAW_OUT" -w '%{http_code}' "$HOST/api/generate" -d @"$REQ") || die "a curl hívás megszakadt"
log "Válasz megjött $(( $(date +%s) - START )) mp alatt, HTTP $HTTP, nyers válasz: $RAW_OUT"
[ "$HTTP" = "200" ] || die "Ollama hiba: $(jq -r '.error // .' "$RAW_OUT")"

# 6. Diagnosztika
jq -r '"Modell válaszideje: \((.total_duration // 0) / 1e9 | floor) mp (betöltés: \((.load_duration // 0) / 1e9 | floor) mp), " +
       "bemeneti tokenek: \(.prompt_eval_count // "?"), kimeneti tokenek: \(.eval_count // "?"), done_reason: \(.done_reason // "?")"' \
  "$RAW_OUT" | while read -r l; do log "$l"; done
THINK=$(jq -r '.thinking // empty' "$RAW_OUT")
[ -n "$THINK" ] && log "Gondolkodás (első 300 karakter): ${THINK:0:300}"
RESP=$(jq -r '.response // empty' "$RAW_OUT")
if [ -z "$RESP" ]; then
  log "A 'response' mező üres."
  if [ "$(jq -r '.done_reason' "$RAW_OUT")" = "length" ]; then
    if [ -n "$THINK" ]; then
      log "A modell gondolkodással töltötte ki a keretet. Használj -instruct változatot, pl.: ollama pull qwen3-vl:2b-instruct"
    else
      log "A kontextus/kimenet betelt: próbáld NUM_CTX=8192 ./ollama_teszt.sh ..."
    fi
  fi
  exit 1
fi
log "Nyers válasz: $RESP"

# 7. Eredmény
echo "$RESP" | jq . || { log "A válasz nem érvényes JSON"; exit 1; }
