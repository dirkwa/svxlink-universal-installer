#!/usr/bin/env bash
# Contract test: detect-hardware.sh must distinguish stream DIRECTIONS.
# "A card exists" is not "a card can record" — the Pi's onboard
# bcm2835/HDMI devices are playback-only, and proposing one as the RX
# default crashloops svxlink with "Open capture audio device failed"
# (first real Pi 4 install, 2026-07-30). Fixtures model:
#   A) Pi with onboard audio only  -> rx null, tx onboard
#   B) Pi onboard + USB duplex     -> rx AND tx = the USB card (never
#      TX on the headphone jack while RX sits on USB)
#   C) no cards at all             -> rx and tx null
set -euo pipefail
cd "$(dirname "$0")/../.."

DETECT=installer/linux/detect-hardware.sh
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }

run_detect() {
    PROC_ASOUND="$1" HIDRAW_SYS=/nonexistent SERIAL_DIR=/nonexistent \
        GPIOCHIP_GLOB='/nonexistent/*' DT_MODEL=/nonexistent \
        bash "$DETECT"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Fixture A: onboard playback-only card ------------------------------
mkdir -p "$tmp/a/card0/pcm0p"
printf ' 0 [Headphones     ]: bcm2835 - bcm2835 Headphones\n' >"$tmp/a/cards"
printf 'Headphones' >"$tmp/a/card0/id"
out=$(run_detect "$tmp/a")
[[ $(jq -r '.audio.rx' <<<"$out") == "null" ]] \
    || fail "A: playback-only card must NOT become the RX default"
[[ $(jq -r '.audio.tx.card' <<<"$out") == "Headphones" ]] \
    || fail "A: playback-only card should still be the TX default"
[[ $(jq -r '.cards[0].capture' <<<"$out") == "false" ]] \
    || fail "A: cards[] must carry capture=false for a playback-only card"
[[ $(jq -r '.cards[0].playback' <<<"$out") == "true" ]] \
    || fail "A: cards[] must carry playback=true"

# --- Fixture B: onboard (playback-only) at 0, USB duplex at 1 -----------
mkdir -p "$tmp/b/card0/pcm0p" "$tmp/b/card1/pcm0c" "$tmp/b/card1/pcm0p"
printf ' 0 [Headphones     ]: bcm2835 - bcm2835 Headphones\n 1 [Device         ]: USB-Audio - USB Audio Device\n' >"$tmp/b/cards"
printf 'Headphones' >"$tmp/b/card0/id"
printf 'Device' >"$tmp/b/card1/id"
out=$(run_detect "$tmp/b")
[[ $(jq -r '.audio.rx.card' <<<"$out") == "Device" ]] \
    || fail "B: RX default must be the capture-capable USB card"
[[ $(jq -r '.audio.tx.card' <<<"$out") == "Device" ]] \
    || fail "B: TX default must follow the RX card when it can play (not the headphone jack)"
[[ $(jq -r '.audio.rx.dev' <<<"$out") == "alsa:plughw:CARD=Device,DEV=0" ]] \
    || fail "B: rx dev must be plughw:CARD=<id>"

# --- Fixture C: a detected card with NO streams at all -------------------
mkdir -p "$tmp/c/card0"
printf ' 0 [Empty          ]: test - empty card\n' >"$tmp/c/cards"
printf 'Empty' >"$tmp/c/card0/id"
out=$(run_detect "$tmp/c")
[[ $(jq -r '.audio.rx' <<<"$out") == "null" && $(jq -r '.audio.tx' <<<"$out") == "null" ]] \
    || fail "C: a streamless card must yield rx=null and tx=null"
[[ $(jq -r '.cards[0].capture' <<<"$out") == "false" && $(jq -r '.cards[0].playback' <<<"$out") == "false" ]] \
    || fail "C: a streamless card must expose capture=false and playback=false"

# --- Fixture D: no cards -------------------------------------------------
mkdir -p "$tmp/d"
printf '' >"$tmp/d/cards"
out=$(run_detect "$tmp/d")
[[ $(jq -r '.audio.rx' <<<"$out") == "null" && $(jq -r '.audio.tx' <<<"$out") == "null" ]] \
    || fail "D: no cards must yield rx=null and tx=null"

echo "[OK] detect-hardware audio direction contract holds (A/B/C)."
