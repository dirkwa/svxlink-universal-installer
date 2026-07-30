#!/usr/bin/env bash
# Pins the operator-choice preservation contract of the hardware.json
# merge. detect-hardware.sh always re-emits fresh defaults, and a
# documented re-run (`curl … | bash`, or a later `svx audio`/`svx ptt`
# pass) must not silently reset the operator's confirmed picks: RX/TX
# cards, PTT wiring, squelch mode, and the PipeWire/Pulse mitigation
# answer (which gates a re-prompt).
#
# The filter under test is the SAME one the wizards run: both source
# installer/linux/lib/hardware-merge.sh, so this test can't pass against
# a stale copy. Two rules verified:
#   1. Operator sections (audio/ptt/squelch) carried with explicit has(),
#      never `//` — jq's `//` treats stored false/null as empty and would
#      resurrect an operator's opt-out/null on the next detection run.
#   2. Inventory (serial[], gpio) always takes the FRESH values — stale
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

# --- 1. Operator choices survive a re-detect ----------------------------
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
check "operator RX card survives re-detect"        '.audio.rx.card'            "OldRx"
check "operator TX card survives re-detect"        '.audio.tx.card'            "OldTx"
check "hostAudioMitigation choice carried"          '.audio.hostAudioMitigation' "mask"
check "operator PTT wiring survives re-detect"      '.ptt.type'                 "hidraw"
check "false-y ptt.invert carried verbatim (has(), not //)" '.ptt.invert'      "false"
check "operator squelch choice survives re-detect"  '.squelch.type'             "GPIO"
check "fresh serial inventory wins (count)"         '.serial | length'          "1"
check "fresh serial inventory wins (byId)"          '.serial[0].byId'           "/dev/serial/by-id/usb-NEW-if00-port0"
check "fresh gpio inventory wins (model)"           '.gpio.model'               "rpi4"
check "fresh gpio inventory wins (chip count)"      '.gpio.chips | length'      "2"

# --- 2. Stored false-y sections are NOT resurrected by fresh defaults ---
# A stored null audio/ptt (host had no card / operator never configured
# PTT) is a value, not an absence: `//` would replace it with the fresh
# first-card default and silently re-point svxlink at hardware the
# operator never picked. has() must carry the null through (audio then
# gets only the hostAudioMitigation backstop key).
cat >"$tmp/old-null.json" <<'JSON'
{
  "audio": null,
  "ptt": null
}
JSON
hardware_merge "$tmp/old-null.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "stored null audio not resurrected to the fresh card" '.audio | has("rx")' "false"
check "stored null ptt carried as null"                      '.ptt'               "null"
check "mitigation backstop lands on the null-audio carry"    '.audio.hostAudioMitigation' "none"

# --- 3. Legacy file without hostAudioMitigation gets the backstop -------
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
check "legacy audio carry keeps the operator card" '.audio.rx.card'             "OldRx"
check "legacy audio carry gains the mitigation backstop" '.audio.hostAudioMitigation' "none"

# --- 4. First merge ever (empty old file) keeps fresh detection ---------
echo '{}' >"$tmp/old-empty.json"
hardware_merge "$tmp/old-empty.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "no old audio section: fresh detection kept"  '.audio.rx.card'  "Fresh"
check "no old ptt section: fresh default kept"      '.ptt.type'       "none"

if (( fail )); then
    echo
    echo "[ERR] hardware.json merge contract broken — see entries above." >&2
    exit 1
fi
echo "[OK] hardware.json merge preserves operator choices and refreshes inventory."
