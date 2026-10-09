#!/usr/bin/env bash
# Gázóra leolvasás lokálisan, Ollamával, ugyanazzal a prompttal, mint az Apps Scriptben.
# Használat:  ./ollama_teszt.sh kep.jpg [modell]
# Előtte:     ollama pull qwen3-vl:2b-instruct
# Az "-instruct" változat kell: a sima qwen3-vl:2b gondolkodó (thinking) változat, ami
# a think:false ellenére is sokáig gondolkodik, és nem marad helye a válasznak.
# Kell hozzá: curl, jq, base64 (macOS-en a kicsinyítéshez a beépített sips)
#
# A lépések naplója a stderr-re megy ([HH:MM:SS] előtaggal), az eredmény JSON a stdout-ra.
# A nyers Ollama-választ elmenti: ollama_valasz.json (a script mellé, az aktuális mappába);
# egy esetleges újrapróbálkozás a ollama_valasz.retry1.json, .retry2.json stb. fájlba kerül.
#
# Validáció és újrafinomítás (env változókkal hangolható):
#   MAX_RETRIES   - hány próbálkozás engedett összesen, ha a válasz nem áll meg a validáción
#                   (alapértelmezett: 2, azaz 1 újrapróbálkozás)
#   RETRY_MODEL   - (alapértelmezett: qwen3.5:4b; üresre állítva kikapcsol) ha meg van adva és eltér a MODEL-től, az utolsó próbálkozás ezzel (jellemzően
#                   egy erősebb) modellel megy, a korábbiak a sima MODEL-lel
#   MAX_INT_DIGITS- az integer_part legfeljebb ennyi számjegyből állhat (alapértelmezett: 5)
# A validáció szabálya: ha is_gas_meter=true, a decimal_part pontosan 3 számjegy kell legyen,
# az integer_part pedig 1..MAX_INT_DIGITS számjegy - egyébként új próbálkozás indul.
set -euo pipefail

IMG="${1:?Használat: $0 kep.jpg [modell]}"
MODEL="${2:-qwen3-vl:2b-instruct}"
HOST="${OLLAMA_HOST_URL:-http://localhost:11434}"
NUM_CTX="${NUM_CTX:-4096}"
MAX_PX="${MAX_PX:-1280}"
RAW_OUT="ollama_valasz.json"
MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_MODEL="${RETRY_MODEL-qwen3.5:4b}"
MAX_INT_DIGITS="${MAX_INT_DIGITS:-5}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "HIBA: $*"; exit 1; }
size() { du -h "$1" | cut -f1; }

PROMPT='This is a photo of a household gas meter with a mechanical drum counter (m³).
Read the counter value.
- integer_part: the digits before the decimal point, usually on a black/dark background (typically 5 digits). Keep leading zeros.
- decimal_part: the digits after the decimal point, usually on a red background or after a comma (typically 3 digits). Empty string if not visible.
- If a drum is halfway between two digits, use the smaller digit (the one rolling out), except 9→0 where you use 9.
- last_drum_upper / last_drum_lower: look only at the rightmost drum (last digit of decimal_part). Give the digit (or partial digit) visible in the upper half and in the lower half of its window. If one digit is centered, give that same digit in both.
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
    "last_drum_upper": {"type": "string"},
    "last_drum_lower": {"type": "string"},
    "confidence":   {"type": "number"},
    "note":         {"type": "string"}
  },
  "required": ["is_gas_meter", "integer_part", "decimal_part", "confidence"]
}'

# 1. Előfeltételek
log "Kép: $IMG ($( [ -f "$IMG" ] && size "$IMG" || echo 'NEM TALÁLHATÓ'))"
[ -f "$IMG" ] || die "a képfájl nem létezik"
for c in curl jq base64; do command -v "$c" >/dev/null || die "hiányzik: $c"; done

# 2. Ollama szerver és modell(ek)
VER=$(curl -s --max-time 5 "$HOST/api/version" | jq -r '.version // empty' || true)
[ -n "$VER" ] || die "az Ollama nem érhető el itt: $HOST (fut az Ollama app / 'ollama serve'?)"
log "Ollama szerver OK, verzió: $VER"
check_model() {
  curl -s "$HOST/api/tags" | jq -e --arg m "$1" '.models[] | select(.name == $m or .model == $m)' >/dev/null \
    || die "a(z) $1 modell nincs letöltve. Futtasd: ollama pull $1"
}
check_model "$MODEL"
log "Modell megvan: $MODEL (num_ctx=$NUM_CTX)"
if [ -n "$RETRY_MODEL" ] && [ "$RETRY_MODEL" != "$MODEL" ]; then
  check_model "$RETRY_MODEL"
  log "Erősebb (retry) modell megvan: $RETRY_MODEL"
fi

# 3. Kicsinyítés
TMP=$(mktemp); SMALL="$(mktemp).jpg"; trap 'rm -f "$TMP" "$SMALL"' EXIT
if command -v sips >/dev/null; then
  sips -Z "$MAX_PX" -s format jpeg "$IMG" --out "$SMALL" >/dev/null
  DIM=$(sips -g pixelWidth -g pixelHeight "$SMALL" | awk '/pixel/{print $2}' | paste -sd x -)
  log "Kicsinyítve: ${DIM} px, $(size "$SMALL")"
  IMG="$SMALL"
else
  log "sips nem elérhető, eredeti méretben küldöm"
fi
base64 < "$IMG" | tr -d '\n' > "$TMP"

# 4. Egy próbálkozás: kérés összeállítása, hívás, diagnosztika.
# Siker esetén a válasz JSON-t az ATTEMPT_RESP globális változóba teszi és 0-val tér vissza.
# think:false - a qwen3-vl "gondolkodó" modell; gondolkodással a válasz a 'thinking' mezőbe
# kerülhet, a 'response' pedig üres maradhat.
# Opcionális 3. paraméter: visszajelzés az előző (hibás) válaszról, ezt a prompt végére fűzi.
# Nélküle temperature=0 mellett a modell szó szerint ugyanazt válaszolná újra.
run_attempt() {
  local model="$1" out_file="$2" feedback="${3:-}" req_file start http think resp prompt
  prompt="$PROMPT"
  [ -n "$feedback" ] && prompt="$prompt"$'\n\n'"$feedback"
  req_file=$(mktemp)
  jq -n --arg model "$model" --arg prompt "$prompt" --rawfile img "$TMP" --argjson schema "$SCHEMA" \
    --argjson ctx "$NUM_CTX" \
    '{model: $model, prompt: $prompt, images: [$img], format: $schema, stream: false, think: false,
      options: {temperature: 0, num_ctx: $ctx, num_predict: 300}}' > "$req_file"
  log "Kérés mérete: $(size "$req_file"), modell: $model. Küldés... (az első futásnál a modell betöltése is eltarthat egy ideig)"

  start=$(date +%s)
  http=$(curl -s -o "$out_file" -w '%{http_code}' "$HOST/api/generate" -d @"$req_file") || die "a curl hívás megszakadt"
  rm -f "$req_file"
  log "Válasz megjött $(( $(date +%s) - start )) mp alatt, HTTP $http, nyers válasz: $out_file"
  [ "$http" = "200" ] || die "Ollama hiba: $(jq -r '.error // .' "$out_file")"

  jq -r '"Modell válaszideje: \((.total_duration // 0) / 1e9 | floor) mp (betöltés: \((.load_duration // 0) / 1e9 | floor) mp), " +
         "bemeneti tokenek: \(.prompt_eval_count // "?"), kimeneti tokenek: \(.eval_count // "?"), done_reason: \(.done_reason // "?")"' \
    "$out_file" | while read -r l; do log "$l"; done

  think=$(jq -r '.thinking // empty' "$out_file")
  [ -n "$think" ] && log "Gondolkodás (első 300 karakter): ${think:0:300}"
  resp=$(jq -r '.response // empty' "$out_file")
  if [ -z "$resp" ]; then
    log "A 'response' mező üres (modell: $model)."
    if [ "$(jq -r '.done_reason' "$out_file")" = "length" ]; then
      if [ -n "$think" ]; then
        log "A modell gondolkodással töltötte ki a keretet. Használj -instruct változatot, pl.: ollama pull qwen3-vl:2b-instruct"
      else
        log "A kontextus/kimenet betelt: próbáld NUM_CTX=8192 ./run.sh ..."
      fi
    fi
    return 1
  fi
  if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
    log "A válasz nem érvényes JSON (modell: $model): $resp"
    return 1
  fi
  log "Nyers válasz (modell: $model): $resp"
  ATTEMPT_RESP="$resp"
}

# 5. Validáció: 3 pontos decimal_part és ésszerű hosszúságú integer_part.
# Ha a számláló nem is gázóra (is_gas_meter=false), nincs mit validálni.
# Hiba esetén a VALIDATION_REASON-be teszi az okot és 1-gyel tér vissza.
validate_response() {
  local resp="$1" is_meter int_part dec_part
  is_meter=$(echo "$resp" | jq -r '.is_gas_meter // false')
  if [ "$is_meter" != "true" ]; then
    return 0
  fi
  int_part=$(echo "$resp" | jq -r '.integer_part // ""')
  dec_part=$(echo "$resp" | jq -r '.decimal_part // ""')
  if ! [[ "$int_part" =~ ^[0-9]{1,${MAX_INT_DIGITS}}$ ]]; then
    VALIDATION_REASON="integer_part hibás vagy túl nagy: '$int_part' (legfeljebb $MAX_INT_DIGITS számjegy várt)"
    VALIDATION_HINT="integer_part '$int_part' is invalid: it must be 1 to $MAX_INT_DIGITS digits, only the digits before the decimal point."
    return 1
  fi
  if ! [[ "$dec_part" =~ ^[0-9]{3}$ ]]; then
    VALIDATION_REASON="decimal_part nem pontosan 3 számjegy: '$dec_part'"
    VALIDATION_HINT="decimal_part '$dec_part' is invalid: it must be exactly 3 digits. All digits after the comma / in the red area belong to decimal_part, none of them to integer_part. If the last drum is rolling, use the smaller digit."
    return 1
  fi
  return 0
}

# 5b. Az utolsó (folyamatosan forgó) dob korrekciója logikával: a dob ablakában egyszerre
# legfeljebb két egymást követő számjegy látszik. Ha a modell szerint fent és lent két
# egymást követő jegy van (pl. fent 6 alja, lent 7 teteje), a kisebbet vesszük, ami
# a számlálás irányából adódóan a felső; 9/0 átmenetnél a 9-et. Ezzel felülírjuk a
# decimal_part utolsó jegyét. Ha a két jegy nem egymást követő, nem nyúlunk hozzá.
apply_last_drum_logic() {
  local resp="$1" up lo dec digit
  up=$(echo "$resp" | jq -r '.last_drum_upper // ""')
  lo=$(echo "$resp" | jq -r '.last_drum_lower // ""')
  dec=$(echo "$resp" | jq -r '.decimal_part // ""')
  if ! [[ "$up" =~ ^[0-9]$ && "$lo" =~ ^[0-9]$ && "$dec" =~ ^[0-9]+$ ]]; then
    echo "$resp"; return
  fi
  if [ "$up" = "$lo" ]; then
    digit="$up"
  elif [ "$lo" = "$(( (up + 1) % 10 ))" ]; then
    digit="$up"
  elif [ "$up" = "$(( (lo + 1) % 10 ))" ]; then
    digit="$lo"
  else
    log "Utolsó dob: fent '$up', lent '$lo' nem egymást követő, a modell olvasata marad"
    echo "$resp"; return
  fi
  if [ "${dec: -1}" != "$digit" ]; then
    log "Utolsó dob: fent '$up', lent '$lo' -> '$digit' (modell: '${dec: -1}'), decimal_part: $dec -> ${dec%?}$digit"
  fi
  echo "$resp" | jq -c --arg d "${dec%?}$digit" '.decimal_part = $d'
}

# 6. Próbálkozási sorozat összeállítása: MAX_RETRIES próbálkozás a MODEL-lel,
# az utolsó helyett RETRY_MODEL-lel, ha az meg van adva, eltér a MODEL-től, és van
# egynél több próbálkozás (különben az első és egyetlen próbálkozás is RETRY_MODEL-re
# cserélődne, és a MODEL soha nem futna le).
declare -a ATTEMPT_MODELS=()
for ((i = 0; i < MAX_RETRIES; i++)); do ATTEMPT_MODELS+=("$MODEL"); done
if [ -n "$RETRY_MODEL" ] && [ "$RETRY_MODEL" != "$MODEL" ] && [ "$MAX_RETRIES" -ge 2 ]; then
  ATTEMPT_MODELS[${#ATTEMPT_MODELS[@]}-1]="$RETRY_MODEL"
fi

FINAL_RESP=""
FEEDBACK=""
for idx in "${!ATTEMPT_MODELS[@]}"; do
  M="${ATTEMPT_MODELS[$idx]}"
  ATTEMPT_OUT="$RAW_OUT"
  [ "$idx" -gt 0 ] && ATTEMPT_OUT="${RAW_OUT%.json}.retry${idx}.json"
  log "--- $(( idx + 1 ))/${#ATTEMPT_MODELS[@]}. próbálkozás, modell: $M ---"
  # Az előző válaszra vonatkozó visszajelzés csak ugyanannak a modellnek megy: egy másik
  # (erősebb) modell különben a hibás előző olvasathoz igazodna, ahelyett hogy újraolvasná a képet.
  [ "$idx" -gt 0 ] && [ "$M" != "${ATTEMPT_MODELS[$idx-1]}" ] && FEEDBACK=""
  if ! run_attempt "$M" "$ATTEMPT_OUT" "$FEEDBACK"; then
    continue
  fi
  ATTEMPT_RESP=$(apply_last_drum_logic "$ATTEMPT_RESP")
  FINAL_RESP="$ATTEMPT_RESP"
  if validate_response "$ATTEMPT_RESP"; then
    break
  fi
  log "Validáció sikertelen: $VALIDATION_REASON"
  FEEDBACK="IMPORTANT: your previous answer was integer_part='$(echo "$ATTEMPT_RESP" | jq -r '.integer_part // ""')', decimal_part='$(echo "$ATTEMPT_RESP" | jq -r '.decimal_part // ""')'. $VALIDATION_HINT Read every drum again carefully, left to right."
done

[ -n "$FINAL_RESP" ] || die "minden próbálkozás sikertelen volt (üres vagy érvénytelen válasz)"

# 7. Eredmény
echo "$FINAL_RESP" | jq . || { log "A válasz nem érvényes JSON"; exit 1; }
