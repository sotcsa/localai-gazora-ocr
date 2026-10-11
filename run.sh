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
#                   (alapértelmezett: 1, azaz nincs újrapróbálkozás: egy modell van, ugyanaz a válasz jönne)
#   KEEP_ALIVE    - meddig maradjon a modell a memóriában (alapértelmezett: 30m)
#   ZOOM_ALWAYS   - true: érvényes olvasatnál mindig fut a nagyítás (alapértelmezett), false: csak sarokesetben
#   RETRY_MODEL   - (alapértelmezett: üres = kikapcsolva) ha meg van adva és eltér a MODEL-től, az utolsó próbálkozás ezzel (jellemzően
#                   egy erősebb) modellel megy, a korábbiak a sima MODEL-lel
#   INT_DIGITS    - az integer_part pontosan ennyi számjegy (alapértelmezett: 5, a gázórák fekete
#                   dobjainak száma). Ha egy jegy kimarad (pl. megcsillan), új próbálkozás indul.
#   ZOOM_MODEL    - (alapértelmezett: qwen3.5:4b; üresre állítva kikapcsol) ha az utolsó dob két
#                   számjegy között áll, ez a modell megkeresi a tizedes mezőt, a script kivágja
#                   az eredeti képből, és a nagyított kivágáson újra megkérdezi az utolsó dobot.
#                   Csak macOS-en (sips) és csak ebben a sarokesetben fut.
# A validáció szabálya: ha is_gas_meter=true, a decimal_part pontosan 3 számjegy kell legyen,
# az integer_part pedig pontosan INT_DIGITS számjegy - egyébként új próbálkozás indul.
set -euo pipefail

IMG="${1:?Használat: $0 kep.jpg [modell]}"
MODEL="${2:-qwen3.5:4b}"
HOST="${OLLAMA_HOST_URL:-http://localhost:11434}"
NUM_CTX="${NUM_CTX:-4096}"
MAX_PX="${MAX_PX:-1280}"
RAW_OUT="ollama_valasz.json"
MAX_RETRIES="${MAX_RETRIES:-1}"
RETRY_MODEL="${RETRY_MODEL-}"
KEEP_ALIVE="${KEEP_ALIVE:-30m}"
ZOOM_ALWAYS="${ZOOM_ALWAYS:-true}"
INT_DIGITS="${INT_DIGITS:-5}"
ZOOM_MODEL="${ZOOM_MODEL-qwen3.5:4b}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "HIBA: $*"; exit 1; }
size() { du -h "$1" | cut -f1; }

PROMPT='This is a photo of a household gas meter with a mechanical drum counter (m³).
Read the counter value.
- integer_part: the digits before the decimal point, usually on a black/dark background (typically 5 digits). Keep leading zeros.
- decimal_part: the digits after the decimal point, usually on a red background or after a comma (typically 3 digits). Empty string if not visible.
- If a drum is halfway between two digits, use the smaller digit (the one rolling out), except 9→0 where you use 9.
- last_drum_rolling: true if the rightmost drum is between two digits (parts of two different digits visible in its window), otherwise false.
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
    "last_drum_rolling": {"type": "boolean"},
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
if [ -n "$ZOOM_MODEL" ] && [ "$ZOOM_MODEL" != "$MODEL" ]; then
  check_model "$ZOOM_MODEL"
  log "Nagyító (zoom) modell megvan: $ZOOM_MODEL"
fi

# 3. Kicsinyítés
ORIG_IMG="$IMG"
TMP=$(mktemp); SMALL="$(mktemp).jpg"; CROP="$(mktemp).jpg"; CROP_B64=$(mktemp)
trap 'rm -f "$TMP" "$SMALL" "$CROP" "$CROP_B64"' EXIT
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
    --argjson ctx "$NUM_CTX" --arg ka "$KEEP_ALIVE" \
    '{model: $model, prompt: $prompt, images: [$img], format: $schema, stream: false, think: false, keep_alive: $ka,
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

# 5. Validáció: 3 jegyű decimal_part és INT_DIGITS jegyű integer_part.
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
  if ! [[ "$int_part" =~ ^[0-9]{${INT_DIGITS}}$ ]]; then
    VALIDATION_REASON="integer_part nem pontosan $INT_DIGITS számjegy: '$int_part'"
    VALIDATION_HINT="integer_part '$int_part' is invalid: it must be exactly $INT_DIGITS digits (one per black drum before the comma, keep leading zeros). A digit may be partly hidden by glare or reflection: still read it."
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

# 5c. Nagyítás az utolsó dobra (csak sarokesetben, lásd ZOOM_MODEL).
# Egy egyszerű JSON-kérés a ZOOM_MODEL-nek; a 'response' mezőt adja vissza (üres, ha hibás).
ask_json() {
  local prompt="$1" img_b64="$2" schema="$3" out_file="$4" req_file http
  req_file=$(mktemp)
  jq -n --arg model "$ZOOM_MODEL" --arg prompt "$prompt" --rawfile img "$img_b64" --argjson schema "$schema" \
    --argjson ctx "$NUM_CTX" --arg ka "$KEEP_ALIVE" \
    '{model: $model, prompt: $prompt, images: [$img], format: $schema, stream: false, think: false, keep_alive: $ka,
      options: {temperature: 0, num_ctx: $ctx, num_predict: 100}}' > "$req_file"
  http=$(curl -s -o "$out_file" -w '%{http_code}' "$HOST/api/generate" -d @"$req_file") || http=000
  rm -f "$req_file"
  [ "$http" = "200" ] && jq -r '.response // empty' "$out_file"
}

# 1) a ZOOM_MODEL megadja a piros tizedes mező helyét (0-1000 relatív koordináták),
# 2) a script kivágja az eredeti felbontású képből (15% ráhagyással) és nagyítja,
# 3) a kivágáson megkérdezi, mi látszik az utolsó dob ablakának felső és alsó felében.
# Az eredményt a last_drum_upper/lower mezőkbe írja; a döntést utána az apply_last_drum_logic hozza.
# Bármilyen hiba esetén az eredeti választ adja vissza.
zoom_last_drum() {
  local resp="$1" bbox x1 y1 x2 y2 W H px py cx cy cw ch drum up lo dec want
  local t0; t0=$(date +%s)
  bbox=$(ask_json 'Locate the red-framed area with the decimal digits of the gas meter counter (after the comma, left of m³). Return its bounding box as bbox_2d [x1, y1, x2, y2] in relative coordinates 0-1000.' \
    "$TMP" '{"type":"object","properties":{"bbox_2d":{"type":"array","items":{"type":"integer"}}},"required":["bbox_2d"]}' \
    "${RAW_OUT%.json}.zoom_bbox.json" | jq -r '.bbox_2d | select(length == 4) | map(tostring) | join(" ")' 2>/dev/null || true)
  read -r x1 y1 x2 y2 <<< "$bbox"
  if ! [[ "$x1" =~ ^[0-9]+$ && "$y1" =~ ^[0-9]+$ && "$x2" =~ ^[0-9]+$ && "$y2" =~ ^[0-9]+$ ]] \
     || [ "$x2" -le "$x1" ] || [ "$y2" -le "$y1" ] || [ "$x2" -gt 1000 ] || [ "$y2" -gt 1000 ]; then
    log "Nagyítás: nem kaptam használható helyet a tizedes mezőre ('$bbox'), kihagyom"
    echo "$resp"; return
  fi
  W=$(sips -g pixelWidth "$ORIG_IMG" | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$ORIG_IMG" | awk '/pixelHeight/{print $2}')
  px=$(( (x2 - x1) * 15 / 100 )); py=$(( (y2 - y1) * 15 / 100 ))
  x1=$(( x1 - px < 0 ? 0 : x1 - px )); y1=$(( y1 - py < 0 ? 0 : y1 - py ))
  x2=$(( x2 + px > 1000 ? 1000 : x2 + px )); y2=$(( y2 + py > 1000 ? 1000 : y2 + py ))
  cx=$(( x1 * W / 1000 )); cy=$(( y1 * H / 1000 )); cw=$(( (x2 - x1) * W / 1000 )); ch=$(( (y2 - y1) * H / 1000 ))
  sips -s format jpeg -c "$ch" "$cw" --cropOffset "$cy" "$cx" "$ORIG_IMG" --out "$CROP" >/dev/null
  sips -Z 1024 "$CROP" >/dev/null
  base64 < "$CROP" | tr -d '\n' > "$CROP_B64"
  log "Nagyítás: tizedes mező [$x1,$y1,$x2,$y2], kivágás ${cw}x${ch} px az eredetiből"

  drum=$(ask_json 'Close-up of the decimal digits of a gas meter drum counter. Look ONLY at the rightmost drum (the last digit, with tick marks). It may be rolling between two digits: then the bottom part of one digit is visible in the upper half of the window and the top part of the next digit in the lower half. upper: the digit (or partial digit) in the upper half of the rightmost window. lower: the digit (or partial digit) in the lower half. If one digit is centered, give it in both. decimals: all digits in the red-framed area, left to right (empty if there is no red-framed area in the image).' \
    "$CROP_B64" '{"type":"object","properties":{"decimals":{"type":"string"},"upper":{"type":"string"},"lower":{"type":"string"}},"required":["decimals","upper","lower"]}' \
    "${RAW_OUT%.json}.zoom_drum.json" || true)
  up=$(echo "$drum" | jq -r '.upper // ""' 2>/dev/null || true)
  lo=$(echo "$drum" | jq -r '.lower // ""' 2>/dev/null || true)
  dec=$(echo "$drum" | jq -r '.decimals // ""' 2>/dev/null | tr -cd '0-9' || true)
  log "Nagyítás ($(( $(date +%s) - t0 )) mp): tizedes jegyek '$dec', utolsó dob fent '$up', lent '$lo'"
  # Ellenőrzés: ha a bbox rossz helyre mutatott, a kivágáson nem a tizedes mező van. Az első két
  # tizedes jegynek egyeznie kell a fő olvasattal, különben a nagyítás eredményét eldobjuk.
  want=$(echo "$resp" | jq -r '.decimal_part // ""' | cut -c1-2)
  if [ "${dec:0:2}" != "$want" ]; then
    log "Nagyítás: a kivágáson a tizedes jegyek ('$dec') nem egyeznek a leolvasással ('$want'), eldobom"
    echo "$resp"; return
  fi
  if ! [[ "$up" =~ ^[0-9]$ && "$lo" =~ ^[0-9]$ ]]; then
    echo "$resp"; return
  fi
  echo "$resp" | jq -c --arg u "$up" --arg l "$lo" \
    '.last_drum_upper = $u | .last_drum_lower = $l | .last_drum_rolling = ($u != $l)'
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
FINAL_VALID=false
ROLLING_SEEN=false
USED_RETRY_MODEL=false
FEEDBACK=""
for idx in "${!ATTEMPT_MODELS[@]}"; do
  M="${ATTEMPT_MODELS[$idx]}"
  ATTEMPT_OUT="$RAW_OUT"
  [ "$idx" -gt 0 ] && ATTEMPT_OUT="${RAW_OUT%.json}.retry${idx}.json"
  log "--- $(( idx + 1 ))/${#ATTEMPT_MODELS[@]}. próbálkozás, modell: $M ---"
  # Az előző válaszra vonatkozó visszajelzés csak ugyanannak a modellnek megy: egy másik
  # (erősebb) modell különben a hibás előző olvasathoz igazodna, ahelyett hogy újraolvasná a képet.
  [ "$idx" -gt 0 ] && [ "$M" != "${ATTEMPT_MODELS[$idx-1]}" ] && FEEDBACK=""
  [ "$M" != "$MODEL" ] && USED_RETRY_MODEL=true
  if ! run_attempt "$M" "$ATTEMPT_OUT" "$FEEDBACK"; then
    continue
  fi
  # A forgást bármelyik (akár érvénytelen) próbálkozás jelezheti: a modellek ebben nem egységesek.
  if echo "$ATTEMPT_RESP" | jq -e '.last_drum_rolling == true or
       ((.last_drum_upper // "") != (.last_drum_lower // ""))' >/dev/null; then
    ROLLING_SEEN=true
  fi
  ATTEMPT_RESP=$(apply_last_drum_logic "$ATTEMPT_RESP")
  FINAL_RESP="$ATTEMPT_RESP"
  if validate_response "$ATTEMPT_RESP"; then
    FINAL_VALID=true
    break
  fi
  log "Validáció sikertelen: $VALIDATION_REASON"
  FEEDBACK="IMPORTANT: your previous answer was integer_part='$(echo "$ATTEMPT_RESP" | jq -r '.integer_part // ""')', decimal_part='$(echo "$ATTEMPT_RESP" | jq -r '.decimal_part // ""')'. $VALIDATION_HINT Read every drum again carefully, left to right."
done

[ -n "$FINAL_RESP" ] || die "minden próbálkozás sikertelen volt (üres vagy érvénytelen válasz)"

# 6b. Sarokeset: az utolsó dob két számjegy között áll -> nagyított második ránézés.
# Csak érvényes gázóra-olvasatnál, ha valamelyik próbálkozás jelezte a forgást, vagy fent/lent
# eltérő jegyet látott, vagy az erősebb modellre kellett váltani (nehéz kép; a qwen3.5:4b a
# forgást magától nem jelzi).
if [ "$FINAL_VALID" = true ] && { [ "$ROLLING_SEEN" = true ] || [ "$USED_RETRY_MODEL" = true ] || [ "$ZOOM_ALWAYS" = true ]; } \
   && [ -n "$ZOOM_MODEL" ] && command -v sips >/dev/null \
   && echo "$FINAL_RESP" | jq -e '.is_gas_meter == true' >/dev/null; then
  if [ "$ROLLING_SEEN" = true ]; then
    log "A modell szerint az utolsó dob két számjegy között állhat, ellenőrzés nagyítással ($ZOOM_MODEL)..."
  elif [ "$USED_RETRY_MODEL" = true ]; then
    log "Nehéz kép (erősebb modell kellett), az utolsó dob ellenőrzése nagyítással ($ZOOM_MODEL)..."
  else
    log "Az utolsó dob ellenőrzése nagyítással ($ZOOM_MODEL, ZOOM_ALWAYS)..."
  fi
  FINAL_RESP=$(apply_last_drum_logic "$(zoom_last_drum "$FINAL_RESP")")
fi

# 7. Eredmény
echo "$FINAL_RESP" | jq . || { log "A válasz nem érvényes JSON"; exit 1; }
