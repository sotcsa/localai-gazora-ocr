#!/usr/bin/env bash
# Gázóra leolvasás lokálisan, Ollamával, ugyanazzal a prompttal, mint az Apps Scriptben.
# Használat:  ./ollama_teszt.sh kep.jpg [modell]
# Előtte:     ollama pull qwen3-vl:2b
# num_ctx: 4096 – az alapértelmezett nagy kontextus (pl. 65536) több GB extra memóriát foglal.
# Kell hozzá: curl, jq, base64
set -euo pipefail

IMG="$1"
MODEL="${2:-qwen3-vl:2b}"

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

# A képet fájlon keresztül adjuk át (nagy fotónál a parancssori argumentum túl hosszú lenne).
TMP=$(mktemp); SMALL="$(mktemp).jpg"; trap 'rm -f "$TMP" "$SMALL"' EXIT

# Kicsinyítés max. 1280 px-re: a teljes felbontású telefonfotó több ezer képtokent és sok memóriát eszik.
if command -v sips >/dev/null; then          # macOS beépített eszköz
  sips -Z 1280 -s format jpeg "$IMG" --out "$SMALL" >/dev/null
  IMG="$SMALL"
fi
base64 < "$IMG" | tr -d '\n' > "$TMP"

jq -n --arg model "$MODEL" --arg prompt "$PROMPT" --rawfile img "$TMP" --argjson schema "$SCHEMA" \
  '{model: $model, prompt: $prompt, images: [$img], format: $schema, stream: false, options: {temperature: 0, num_ctx: 4096}}' \
| curl -s http://localhost:11434/api/generate -d @- \
| jq -r '.response' | jq .

