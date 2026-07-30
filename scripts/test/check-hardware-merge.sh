#!/usr/bin/env bash
# Pins the operator-choice preservation contract of the hardware.json
# merge. detect-hardware.sh always re-emits fresh defaults, and a
# documented re-run (`curl … | bash`, or a later `svx audio`/`svx ptt`
# pass) must not silently reset the operator's confirmed picks: PTT
# wiring, squelch mode, and the PipeWire/Pulse mitigation answer (which
# gates a re-prompt).
#
# The filter under test is the SAME one the wizards run: both source
# installer/linux/lib/hardware-merge.sh, so this test can't pass against
# a stale copy. Three rules verified:
#   1. Operator sections (ptt/squelch/audio.hostAudioMitigation) carried
#      with explicit has(), never `//` — jq's `//` treats stored
#      false/null as empty and would resurrect an operator's opt-out on
#      the next detection run.
#   2. audio.rx/tx always take the FRESH detection values — hardware.json
#      audio is detection output, NOT OperatorIntent. Carrying it froze
#      the first run's (possibly wrong) proposal forever: on the Pi 4 a
#      stale tx=Headphones from the pre-capture-fix detection overrode
#      every corrected re-detect and defeated the install-time parking.
#      The operator's real audio choice lives in svxlink.conf.
#   3. Inventory (serial[], gpio) always takes the FRESH values — stale
#      inventory is what produces AddDevice= lines at vanished nodes.
#
# Run from the repo root.

set -euo pipefail

MERGE_LIB=${MERGE_LIB:-installer/linux/lib/hardware-merge.sh}
if [[ ! -f "$MERGE_LIB" ]]; then
    echo "[ERR] $MERGE_LIB not found (run from repo root)" >&2
    exit 2
fi
# shellcheck source=/dev/null
. "$MERGE_LIB"

if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not available — hardware merge contract not checked"
    exit 0
fi

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check() {
    # $1 = label, $2 = jq filter, $3 = expected — run against merged.json
    local got
    got=$(jq -r "$2" "$tmp/merged.json")
    if [[ "$got" == "$3" ]]; then
        echo "  [OK]   $1"
    else
        echo "  [MISS] $1 (got '$got', want '$3')"
        fail=1
    fi
}

# Fresh detection output: first-card defaults, ptt none, VOX, fresh
# inventory (a NEW serial adapter, an rpi4 chip set).
cat >"$tmp/fresh.json" <<'JSON'
{
  "audio": {
    "rx": { "card": "Fresh", "dev": "alsa:plughw:CARD=Fresh,DEV=0", "sampleRate": 48000 },
    "tx": { "card": "Fresh", "dev": "alsa:plughw:CARD=Fresh,DEV=0", "sampleRate": 48000 },
    "hostAudioMitigation": "none"
  },
  "ptt": { "type": "none", "device": "", "pin": "", "invert": false },
  "squelch": { "type": "VOX" },
  "serial": [ { "byId": "/dev/serial/by-id/usb-NEW-if00-port0", "enabled": false } ],
  "gpio": { "model": "rpi4", "chips": ["/dev/gpiochip0", "/dev/gpiochip4"] }
}
JSON

# --- 1. Operator choices survive; detection audio does NOT --------------
cat >"$tmp/old.json" <<'JSON'
{
  "audio": {
    "rx": { "card": "OldRx", "dev": "alsa:plughw:CARD=OldRx,DEV=0", "sampleRate": 48000 },
    "tx": { "card": "OldTx", "dev": "alsa:plughw:CARD=OldTx,DEV=0", "sampleRate": 48000 },
    "hostAudioMitigation": "mask"
  },
  "ptt": { "type": "hidraw", "device": "/dev/svxlink-ptt", "pin": "GPIO3", "invert": false },
  "squelch": { "type": "GPIO" },
  "serial": [
    { "byId": "/dev/serial/by-id/usb-OLD-if00-port0", "enabled": true },
    { "byId": "/dev/serial/by-id/usb-GONE-if00-port0", "enabled": false }
  ],
  "gpio": { "model": "rpi3", "chips": ["/dev/gpiochip0"] }
}
JSON
hardware_merge "$tmp/old.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "fresh RX detection wins over stored audio"   '.audio.rx.card'            "Fresh"
check "fresh TX detection wins over stored audio"   '.audio.tx.card'            "Fresh"
check "hostAudioMitigation choice carried"          '.audio.hostAudioMitigation' "mask"
check "operator PTT wiring survives re-detect"      '.ptt.type'                 "hidraw"
check "false-y ptt.invert carried verbatim (has(), not //)" '.ptt.invert'      "false"
check "operator squelch choice survives re-detect"  '.squelch.type'             "GPIO"
check "fresh serial inventory wins (count)"         '.serial | length'          "1"
check "fresh serial inventory wins (byId)"          '.serial[0].byId'           "/dev/serial/by-id/usb-NEW-if00-port0"
check "fresh gpio inventory wins (model)"           '.gpio.model'               "rpi4"
check "fresh gpio inventory wins (chip count)"      '.gpio.chips | length'      "2"

# --- 2. THE Pi 4 regression: stale tx must not defeat a corrected detect -
# Old file: the pre-capture-fix detection proposed the onboard bcm2835
# for tx. Fresh (corrected) detection: no capture card -> rx AND tx null.
# The merge must let the fresh nulls through so install.sh parks the
# logic sides — carrying the stale audio is exactly what crashlooped the
# real Pi 4 a second time.
cat >"$tmp/fresh-nullaudio.json" <<'JSON'
{
  "audio": { "rx": null, "tx": null },
  "ptt": { "type": "none", "device": "", "pin": "", "invert": false },
  "squelch": { "type": "VOX" },
  "serial": [],
  "gpio": { "model": "rpi4", "chips": ["/dev/gpiochip0"] }
}
JSON
hardware_merge "$tmp/old.json" "$tmp/fresh-nullaudio.json" >"$tmp/merged.json"
check "stale stored tx does NOT override a corrected null detect" '.audio.tx'  "null"
check "stale stored rx does NOT override a corrected null detect" '.audio.rx'  "null"
check "mitigation still carried alongside the fresh nulls" '.audio.hostAudioMitigation' "mask"

# --- 3. Operator false-y sections are NOT resurrected by fresh defaults -
# A stored null ptt (operator never configured PTT) is a value, not an
# absence: `//` would replace it with the fresh default. has() must carry
# the null through. Audio in the same old file is null too — and per rule
# 2 the FRESH audio wins (plus the mitigation backstop).
cat >"$tmp/old-null.json" <<'JSON'
{
  "audio": null,
  "ptt": null
}
JSON
hardware_merge "$tmp/old-null.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "null old audio: fresh detection wins (rule 2)"  '.audio.rx.card' "Fresh"
check "stored null ptt carried as null"                '.ptt'           "null"
check "mitigation backstop lands when old file had none" '.audio.hostAudioMitigation' "none"

# --- 4. Legacy file without hostAudioMitigation gets the backstop -------
# (pre-key hardware.json: without the backstop the wizard would lose its
# "already answered" marker and re-prompt forever.)
cat >"$tmp/old-legacy.json" <<'JSON'
{
  "audio": {
    "rx": { "card": "OldRx", "dev": "alsa:plughw:CARD=OldRx,DEV=0", "sampleRate": 48000 },
    "tx": null
  }
}
JSON
hardware_merge "$tmp/old-legacy.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "legacy audio does not shadow fresh detection"     '.audio.rx.card'             "Fresh"
check "legacy audio without the key gets the backstop"   '.audio.hostAudioMitigation' "none"

# --- 5. First merge ever (empty old file) keeps fresh detection ---------
echo '{}' >"$tmp/old-empty.json"
hardware_merge "$tmp/old-empty.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "no old audio section: fresh detection kept"  '.audio.rx.card'  "Fresh"
check "no old ptt section: fresh default kept"      '.ptt.type'       "none"

if (( fail )); then
    echo
    echo "[ERR] hardware.json merge contract broken — see entries above." >&2
    exit 1
fi
echo "[OK] hardware.json merge carries operator choices, refreshes detection + inventory."
