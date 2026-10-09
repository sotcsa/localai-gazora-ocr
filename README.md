# Gázóra leolvasás lokálisan, Ollamával

Fényképről olvassa le egy háztartási gázóra mechanikus dobszámlálóját (m³), lokálisan futó
látó (vision) modellel. A prompt ugyanaz, mint az Apps Scriptes változatban.

```bash
ollama pull qwen3-vl:2b-instruct
ollama pull qwen3.5:4b
./run.sh kep.jpg                 # egy kép
./run_all.sh mappa/              # minden .jpg/.jpeg/.png egy mappában
```

Kell hozzá: `curl`, `jq`, `base64`. Kicsinyítéshez és a nagyításhoz macOS-en a beépített `sips`.
A napló a stderr-re megy (`[HH:MM:SS]` előtaggal), az eredmény JSON a stdout-ra:

```json
{
  "is_gas_meter": true,
  "integer_part": "00000",
  "decimal_part": "136",
  "confidence": 0.95,
  "last_drum_rolling": false,
  "last_drum_upper": "6",
  "last_drum_lower": "7",
  "note": ""
}
```

## Hogyan működik

1. **Kicsinyítés** 1280 px-re (`MAX_PX`), base64.
2. **Leolvasás** a gyors modellel (`qwen3-vl:2b-instruct`), JSON sémával kényszerített kimenettel.
3. **Validáció**: `integer_part` pontosan 5 számjegy (`INT_DIGITS`), `decimal_part` pontosan 3 számjegy.
4. **Újrapróbálkozás**, ha a validáció elbukik:
   - ugyanazzal a modellel → a prompt végére kerül az előző válasz és a hiba oka;
   - az utolsó próbálkozás az erősebb `RETRY_MODEL`-lel (`qwen3.5:4b`) megy, **visszajelzés nélkül**.
5. **Utolsó dob logika** (`apply_last_drum_logic`): a dob ablakában legfeljebb két egymást
   követő számjegy látszik. Ha fent és lent két egymást követő jegy van (pl. fent a 6 alja,
   lent a 7 teteje), a **kisebbet** vesszük, 9/0 átmenetnél a **9-et**.
6. **Nagyítás, csak sarokesetben** (`zoom_last_drum`): ha valamelyik próbálkozás jelezte, hogy
   az utolsó dob két jegy között áll, **vagy** az erősebb `RETRY_MODEL`-re kellett váltani
   (nehéz kép), a `ZOOM_MODEL`
   - megadja a piros tizedes mező helyét (bbox, 0–1000 relatív koordináta),
   - a script kivágja az **eredeti felbontású** képből (+15% ráhagyás) és 1024 px-re nagyítja,
   - a kivágáson megkérdezi: mik a tizedes jegyek, és mi látszik az utolsó dob felső és alsó felében?
   - **ellenőrzés**: ha a kivágáson olvasott első két tizedes jegy nem egyezik a fő olvasattal,
     a bbox rossz helyre mutatott, a nagyítás eredményét eldobja;
   - az 5. pont logikája dönt, és a `last_drum_rolling` mező a nagyítás eredményét tükrözi
     (fent ≠ lent → `true`). Ára kb. +10 mp.

Nyers válaszok (gitignore-olva): `ollama_valasz.json`, `ollama_valasz.retryN.json`,
`ollama_valasz.zoom_bbox.json`, `ollama_valasz.zoom_drum.json`.

## Beállítások (env változók)

| Változó | Alapérték | Jelentés |
|---|---|---|
| 2. paraméter | `qwen3-vl:2b-instruct` | első modell |
| `RETRY_MODEL` | `qwen3.5:4b` | az utolsó próbálkozás modellje; üresre állítva kikapcsol |
| `ZOOM_MODEL` | `qwen3.5:4b` | a nagyítás modellje; üresre állítva kikapcsol |
| `MAX_RETRIES` | `2` | próbálkozások száma összesen |
| `INT_DIGITS` | `5` | `integer_part` pontos hossza |
| `MAX_PX` | `1280` | kicsinyítés hosszabb oldala |
| `NUM_CTX` | `4096` | kontextusablak |
| `OLLAMA_HOST_URL` | `http://localhost:11434` | Ollama szerver |

## Tapasztalatok (2026-10)

### Modellek

| Modell | Tapasztalat |
|---|---|
| `qwen3-vl:2b-instruct` | Gyors (~1 mp), a legtöbb képen jó. Nehéz képen elcsúszik: az első tizedes jegyet az egész részhez veszi (`00001,3` a helyes `00000,13x` helyett). |
| `qwen3.5:4b` | ~10–15 mp. Jól tagol (`00000,139`), jó bboxot ad, a nagyított kivágáson felismeri a két félig látszó jegyet. **Ez a tartalék és a nagyító modell.** |
| `gemma3:4b` | Használhatatlan erre: `0` / `0.000`. |
| `qwen3-vl:2b` (nem instruct) | Gondolkodó változat, `think:false` mellett is kifut a keretből. Az **-instruct** kell. |

### Ami nem működött, és miért

- **Azonos újrapróbálkozás**: `temperature: 0` mellett ugyanarra a kérésre bitre ugyanaz a válasz
  jön. Az újrapróbálkozásnak csak akkor van értelme, ha a kérés változik (visszajelzés vagy más modell).
- **Visszajelzés a 2b modellnek**: kitart a rossz olvasat mellett, a `note`-ban meg is indokolja.
- **Visszajelzés az erősebb modellnek**: a 2b hibás válaszát látva a `qwen3.5:4b` is hozzá
  igazodott (`00001,359`). Ezért modellváltáskor nem megy visszajelzés.
- **Az utolsó dob a teljes képen**: 1280 px-en a dob kb. 30 px széles. Egyik modell sem látja
  külön a két félig látszó jegyet (fent=lent, és mindig mást mond: 9, 5, 7). 2048 px-en sem jobb,
  csak lassabb (31 mp). Ezért kell a kivágás az eredeti képből.
- **A forgás jelzése**: a `qwen3.5:4b` sosem jelezte (`last_drum_rolling: false`), a 2b igen.
  Ezért a nagyítás akkor indul, ha **bármelyik** próbálkozás jelezte, akár érvénytelen válaszban is,
  illetve mindig, ha a 4b-re kellett váltani (ne múljon a 2b véletlen jelzésén).
- **`integer_part` 1..5 jegy engedése**: ha egy jegyen megcsillan a fény, a 2b kihagyja
  (`0218` a helyes `02186` helyett), és ez átment a validáción. Ezért most pontosan 5 jegy kell;
  az újrapróbálkozásnál a 4b helyesen olvasta.
- **Rossz bbox**: a `20260513_192506.jpg`-n a 4b az x-et jól adta meg, az y-t nem (a lenti
  vonalkódos matricára mutatott); a kivágáson `1`/`2`-t olvasott, ebből `811` lett `819` helyett.
  Ezért van a tizedes jegyes ellenőrzés.
- **Új mezők a sémában** megváltoztathatják a fő olvasatot is (a 4b `139` helyett `135`-öt adott).
  Sémamódosítás után mindig újra kell tesztelni.

### Ismert korlátok

- Ha a 2b modell elsőre érvényes választ ad, és nem veszi észre a forgást, a nagyítás nem fut.
- A „4b-re váltott, de forgást senki nem jelzett” ág tesztképen még nem futott (mindkét
  tesztképen a 2b jelzi a forgást).
- A „kisebb jegy” szabály akkor is a kisebbet adja, ha az új jegy már majdnem középen áll
  (`IMG_20250522_093934.jpg`: 418 helyett 417). Ez a szabály szerint helyes, szándékosan maradt így.
- A nagyítás csak macOS-en fut (`sips`).

## Tesztképek

| Kép | Helyes érték | Megjegyzés |
|---|---|---|
| `IMG_20241202_131143_hard.jpg` | `00000,136` | utolsó dob 6→7 között; 2b elcsúszik; csak nagyítással jó |
| `IMG_20250522_093934.jpg` | `00929,417` | utolsó dob 7→8 között, a 8 már majdnem középen |
| `20260513_192506.jpg` | `02186,819` | a 6-on csillanás, a 2b kihagyja; a zoom bbox rossz helyre mutat |

A képek nincsenek a repóban (gitignore).

## Megjegyzések a kód módosításához (embernek és AI-nak)

- A változtatás után futtasd mindkét tesztképen, és nézd meg a naplót is, ne csak a végeredményt.
- A modellek determinisztikusak (`temperature: 0`), de bármilyen promptváltozás eltolhatja az olvasatot.
- A bbox koordináták 0–1000 relatív skálán vannak (qwen konvenció), a script számolja át pixelre.
- `set -euo pipefail` van érvényben: a hívások, amelyek elbukhatnak, `|| true`-val védettek.
