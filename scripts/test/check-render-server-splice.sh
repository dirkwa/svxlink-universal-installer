#!/usr/bin/env bash
# The ENVIRON[] robustness contract of render-server-quadlet.sh's live
# splice: operator content must be DATA, never program text.
#
# The renderer re-injects two things from the live Quadlet into every
# fresh render — the USER ADDITIONS inner lines and the Image= line — via
# awk ENVIRON[] specifically because sed (and awk -v, which processes
# backslash escapes) would reinterpret operator bytes: a `%` in a
# PublishPort, an `&` in a label (sed's "whole match" metachar in the
# replacement), quotes, or a `\` in an annotation would corrupt the
# splice program or the content. This test seeds a live file whose USER
# ADDITIONS carry exactly those hostile bytes plus a digest-pinned
# Image= (what auto-rollback leaves behind: @sha256:<64 hex> — sed-hostile
# via its own metachars-in-path), forces a real template delta so the
# splice-and-write path runs (not the short-circuit), and asserts
# byte-exact survival. Run from the repo root.

set -euo pipefail

RENDER=${RENDER:-installer/linux/render-server-quadlet.sh}
SERVER_TMPL=${SERVER_TMPL:-quadlets/svxlink-server.container.template}

for f in "$RENDER" "$SERVER_TMPL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

snd="$tmp/snd"; mkdir -p "$snd"
snapdir="$tmp/snapshots"
live="$tmp/svxlink-server.container"

hw="$tmp/hardware.json"
cat >"$hw" <<'JSON'
{
  "audio": {
    "rx": { "card": "Device", "dev": "alsa:plughw:CARD=Device,DEV=0", "sampleRate": 48000 },
    "tx": { "card": "Device", "dev": "alsa:plughw:CARD=Device,DEV=0", "sampleRate": 48000 },
    "hostAudioMitigation": "none"
  },
  "ptt": { "type": "none", "device": "", "pin": "", "invert": false },
  "squelch": { "type": "VOX" },
  "serial": [],
  "gpio": { "model": "none", "chips": [] }
}
JSON

render() { # $1=template
    HARDWARE_JSON="$hw" TEMPLATE="$1" OUTPUT="$live" SNAPSHOT_DIR="$snapdir" \
        SND_DIR="$snd" SOUNDS_DIR="$tmp/no-sounds" bash "$RENDER"
}

# Seed the live file from a template MISSING Timezone=local — a real
# template delta, so the later render against the full template must take
# the rewrite path (splice + snapshot + atomic write), not the
# byte-identical short-circuit.
tmpl_notz="$tmp/template-notz"
grep -v '^Timezone=' "$SERVER_TMPL" >"$tmpl_notz"
render "$tmpl_notz" >/dev/null

# Hostile operator content: double/single quotes, %, &, backslashes
# (single and double), sed replacement metachars, awk -v escape bait
# (\n, \t as literal two-character sequences).
nasty=$(cat <<'EOF'
Environment=CUSTOM_MOTD="100% & more \ than 'one' \"quote\""
PodmanArgs=--label note=%h\&x --annotation q='a \& b' --annotation nl='\n\t'
# operator comment with % & \ and "quotes" and a trailing backslash \
EOF
)
digest_image='Image=ghcr.io/dirkwa/svxlink-server@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

# Inject through awk ENVIRON[] here too — the test must not corrupt its
# own fixture the way the production code must not corrupt the splice.
NASTY="$nasty" DIGEST="$digest_image" awk '
    /^Image=/ { print ENVIRON["DIGEST"]; next }
    /^# === BEGIN USER ADDITIONS ===/ { print; print ENVIRON["NASTY"]; next }
    { print }
' "$live" >"$live.edited" && mv "$live.edited" "$live"

# Re-render against the FULL template: Timezone=local comes back (the
# delta) while the digest image and every hostile byte must survive.
if render "$SERVER_TMPL" >/dev/null; then
    ok "re-render with hostile live content exited 0"
else
    miss "re-render with hostile live content exited non-zero"
fi

if grep -qxF 'Timezone=local' "$live"; then
    ok "template delta applied (Timezone=local restored)"
else
    miss "template delta NOT applied — the rewrite path never ran, splice untested"
fi

# Byte-exact, exactly-once survival of every hostile line.
while IFS= read -r line; do
    n=$(grep -cxF "$line" "$live" || true)
    if [[ "$n" == 1 ]]; then
        ok "survived byte-exact: ${line:0:60}"
    else
        miss "corrupted or duplicated (count=$n): ${line:0:60}"
    fi
done <<<"$nasty"

n=$(grep -cxF "$digest_image" "$live" || true)
image_lines=$(grep -c '^Image=' "$live" || true)
if [[ "$n" == 1 && "$image_lines" == 1 ]]; then
    ok "digest-pinned Image= preserved, exactly one Image= line"
else
    miss "digest Image= splice wrong (exact=$n total-image-lines=$image_lines)"
fi

# Stability: a second render against the same template must now
# short-circuit with the hostile content byte-identical — no oscillation
# between renders (a splice that re-encodes anything would ping-pong).
# `|| true` inside the group: if no snapshot was ever taken the dir does
# not exist, find exits 1, and under pipefail the substitution would
# abort the whole test via set -e.
snap_count() { { find "$snapdir" -type f 2>/dev/null || true; } | wc -l; }
before_sha=$(sha256sum "$live" | cut -d' ' -f1)
before_snaps=$(snap_count)
if render "$SERVER_TMPL" >/dev/null; then
    after_sha=$(sha256sum "$live" | cut -d' ' -f1)
    after_snaps=$(snap_count)
    if [[ "$before_sha" == "$after_sha" && "$before_snaps" == "$after_snaps" ]]; then
        ok "second render short-circuits byte-identically (no re-encode drift)"
    else
        miss "second render changed bytes or snapshotted — splice is not stable"
    fi
else
    miss "second render exited non-zero"
fi

if (( fail )); then
    echo
    echo "[ERR] live-splice robustness broken — see entries above." >&2
    exit 1
fi
echo
echo "[OK] USER ADDITIONS + digest Image= survive re-renders byte-exact."
