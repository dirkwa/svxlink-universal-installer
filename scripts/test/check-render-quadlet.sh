#!/usr/bin/env bash
# Fixture-driven contract test of installer/linux/render-server-quadlet.sh
# — the ONE renderer install.sh and `svx render-server` share.
#
# Everything runs against mktemp trees via the renderer's env interface
# (HARDWARE_JSON/TEMPLATE/OUTPUT/SNAPSHOT_DIR/SND_DIR/SOUNDS_DIR), which
# exists precisely so this test can seed present/absent device nodes
# deterministically without touching the host. Cases:
#
#   1. hidraw / serial / gpiod / none PTT types render the right
#      AddDevice= lines (and only those).
#   2. Sounds override dirs: one Volume=...:ro per existing language dir;
#      a missing sounds root renders no sounds mounts.
#   3. Vanished device nodes are DROPPED by the existence guard — an
#      AddDevice= pointing at a missing path fails container create with
#      exit 125 BEFORE svxlink starts, crashlooping the whole node.
#   4. USER ADDITIONS inner lines and the live Image= (the operator's
#      channel-of-record) survive a re-render.
#   5. A malformed render (template lost its [Container]/Image= anchors)
#      is refused non-zero and the live file is left untouched.
#   6. A byte-identical re-render short-circuits: exit 0, no write, no
#      snapshot.
#   7. The RENDERED file has no Exec*/Restart* keys inside [Container]
#      (Quadlet rejects unknown keys per section — the generator would
#      refuse the whole unit and systemctl would report "Unit not found"),
#      carries GroupAdd=keep-groups, and has no UserNS= directive (the
#      root-in-userns ADR; keep-id + --device + keep-groups is
#      podman#28364 territory).
#
# Run from the repo root.

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

# Fixture device nodes. Plain files are enough — the guard is [ -e ].
snd="$tmp/snd";                    mkdir -p "$snd"
hid="$tmp/svxlink-ptt";            : >"$hid"
serial_dir="$tmp/serial-by-id";    mkdir -p "$serial_dir"
ser="$serial_dir/usb-FTDI_TEST-if00-port0"; : >"$ser"
chip="$tmp/gpiochip0";             : >"$chip"
sounds="$tmp/sounds";              mkdir -p "$sounds/de_DE"
sounds_none="$tmp/no-sounds-here"  # never created
snapdir="$tmp/snapshots"

# hardware.json builder following the pinned schema. $1=dest, $2=ptt type,
# $3=ptt device, $4=audio configured (1/0), $5=gpio chips JSON array.
mk_hw() {
    local dest=$1 ptype=$2 pdev=$3 audio=$4 chips=${5:-[]}
    local rx='null' tx='null'
    if [[ "$audio" == 1 ]]; then
        rx='{ "card": "Device", "dev": "alsa:plughw:CARD=Device,DEV=0", "sampleRate": 48000 }'
        tx='{ "card": "Device", "dev": "alsa:plughw:CARD=Device,DEV=0", "sampleRate": 48000 }'
    fi
    cat >"$dest" <<JSON
{
  "audio": {
    "rx": $rx,
    "tx": $tx,
    "hostAudioMitigation": "none"
  },
  "ptt": {
    "type": "$ptype",
    "device": "$pdev",
    "pin": "GPIO3",
    "invert": false
  },
  "squelch": { "type": "VOX" },
  "serial": [],
  "gpio": {
    "model": "none",
    "chips": $chips
  }
}
JSON
}

# One renderer invocation with every path pointed into the fixture tree.
# $1=hardware.json $2=template $3=output $4=sounds root; SND_DIR is the
# fixture /dev/snd stand-in unless the caller overrides it via env.
render() {
    HARDWARE_JSON="$1" TEMPLATE="$2" OUTPUT="$3" SNAPSHOT_DIR="$snapdir" \
        SND_DIR="${SND_DIR_OVERRIDE:-$snd}" SOUNDS_DIR="$4" \
        bash "$RENDER"
}

# `|| true` inside the group: before the first snapshot the dir does not
# exist, find exits 1, and under pipefail the substitution would abort
# the whole test via set -e.
snap_count() { { find "$snapdir" -type f 2>/dev/null || true; } | wc -l; }

# Exec*/Restart* keys must never land inside [Container]: Quadlet rejects
# unknown keys per group and refuses the WHOLE unit. Track the current
# section header; exit 0 (= bad) if a violating line is seen.
container_has_exec_or_restart() {
    awk '
        /^\[/ { sec = $0 }
        sec == "[Container]" && ($0 ~ /^Exec/ || $0 ~ /^Restart/) { bad = 1 }
        END { exit bad ? 0 : 1 }
    ' "$1"
}

# --- 1. PTT type matrix -------------------------------------------------

out="$tmp/out-hidraw.container"
mk_hw "$tmp/hw-hidraw.json" hidraw "$hid" 1
if render "$tmp/hw-hidraw.json" "$SERVER_TMPL" "$out" "$sounds_none" >/dev/null; then
    if grep -qxF "AddDevice=$snd" "$out" && grep -qxF "AddDevice=$hid" "$out"; then
        ok "hidraw: AddDevice for /dev/snd stand-in + PTT symlink"
    else
        miss "hidraw: expected AddDevice lines missing"
    fi
else
    miss "hidraw render exited non-zero"
fi
# Fresh renders must be world-readable — the quadlet generator runs as the
# user, but 0644 is the pinned atomic-write contract.
if [[ "$(stat -c '%a' "$out")" == "644" ]]; then
    ok "rendered file mode is 0644"
else
    miss "rendered file mode is $(stat -c '%a' "$out"), want 0644"
fi

out_serial="$tmp/out-serial.container"
mk_hw "$tmp/hw-serial.json" serial "$ser" 1
if render "$tmp/hw-serial.json" "$SERVER_TMPL" "$out_serial" "$sounds_none" >/dev/null; then
    if grep -qxF "AddDevice=$ser" "$out_serial"; then
        ok "serial: AddDevice for the by-id path"
    else
        miss "serial: AddDevice for the by-id path missing"
    fi
else
    miss "serial render exited non-zero"
fi

out_gpiod="$tmp/out-gpiod.container"
mk_hw "$tmp/hw-gpiod.json" gpiod "$chip" 1 "[\"$chip\"]"
if render "$tmp/hw-gpiod.json" "$SERVER_TMPL" "$out_gpiod" "$sounds_none" >/dev/null; then
    if grep -qxF "AddDevice=$chip" "$out_gpiod"; then
        ok "gpiod: AddDevice for the gpiochip"
    else
        miss "gpiod: AddDevice for the gpiochip missing"
    fi
else
    miss "gpiod render exited non-zero"
fi

# gpiod with an empty ptt.device must fall back to the first detected
# chip (older / hand-edited hardware.json files leave device unset).
out_gpiod2="$tmp/out-gpiod-fallback.container"
mk_hw "$tmp/hw-gpiod2.json" gpiod "" 1 "[\"$chip\"]"
if render "$tmp/hw-gpiod2.json" "$SERVER_TMPL" "$out_gpiod2" "$sounds_none" >/dev/null; then
    if grep -qxF "AddDevice=$chip" "$out_gpiod2"; then
        ok "gpiod: empty ptt.device falls back to gpio.chips[0]"
    else
        miss "gpiod: chips[0] fallback did not render"
    fi
else
    miss "gpiod fallback render exited non-zero"
fi

# none PTT + configured audio: exactly the /dev/snd line, nothing else.
out_none="$tmp/out-none.container"
mk_hw "$tmp/hw-none.json" none "" 1
if render "$tmp/hw-none.json" "$SERVER_TMPL" "$out_none" "$sounds_none" >/dev/null; then
    n=$(grep -c '^AddDevice=' "$out_none" || true)
    if [[ "$n" == 1 ]] && grep -qxF "AddDevice=$snd" "$out_none"; then
        ok "none PTT: only the audio AddDevice remains"
    else
        miss "none PTT: expected exactly one AddDevice (audio), got $n"
    fi
else
    miss "none-PTT render exited non-zero"
fi

# none PTT + unconfigured audio (rx/tx null): zero AddDevice lines. On a
# host that never ran the audio wizard /dev/snd may not even exist — the
# mount must not be emitted at all.
out_bare="$tmp/out-bare.container"
mk_hw "$tmp/hw-bare.json" none "" 0
if render "$tmp/hw-bare.json" "$SERVER_TMPL" "$out_bare" "$sounds_none" >/dev/null; then
    if grep -q '^AddDevice=' "$out_bare"; then
        miss "unconfigured audio still emitted an AddDevice line"
    else
        ok "unconfigured audio + none PTT: no AddDevice lines"
    fi
else
    miss "bare render exited non-zero"
fi

# --- 2. Sounds override dirs --------------------------------------------

out_snd="$tmp/out-sounds.container"
if render "$tmp/hw-hidraw.json" "$SERVER_TMPL" "$out_snd" "$sounds" >/dev/null; then
    if grep -qxF "Volume=$sounds/de_DE:/usr/share/svxlink/sounds/de_DE:ro" "$out_snd"; then
        ok "sounds: per-language ro shadow mount rendered"
    else
        miss "sounds: de_DE Volume line missing"
    fi
else
    miss "sounds render exited non-zero"
fi
# The no-override case must not invent sounds mounts (out-hidraw above ran
# with the absent sounds root).
if grep -q '/usr/share/svxlink/sounds/' "$out"; then
    miss "sounds mount rendered although the override root is absent"
else
    ok "sounds: absent override root renders no sounds mounts"
fi

# --- 3. Vanished device nodes dropped by the existence guard ------------

out_gone="$tmp/out-gone.container"
mk_hw "$tmp/hw-gone.json" hidraw "$tmp/never-created-ptt" 1
if render "$tmp/hw-gone.json" "$SERVER_TMPL" "$out_gone" "$sounds_none" >/dev/null; then
    if grep -qF "AddDevice=$tmp/never-created-ptt" "$out_gone"; then
        miss "vanished PTT node leaked into the render (would exit-125-brick the unit)"
    else
        ok "vanished PTT node dropped (unit not bricked)"
    fi
    # The still-present audio device must survive the same render — the
    # guard drops only the missing node, never the whole block.
    if grep -qxF "AddDevice=$snd" "$out_gone"; then
        ok "present audio device kept alongside the dropped one"
    else
        miss "guard dropped the present audio device too"
    fi
else
    miss "vanished-node render exited non-zero (guard must make the skip a success)"
fi

# Same guard, audio direction: a vanished /dev/snd (soundless host after a
# card was unplugged) must drop the audio AddDevice, not brick the unit.
out_nosnd="$tmp/out-nosnd.container"
if SND_DIR_OVERRIDE="$tmp/never-created-snd" \
    render "$tmp/hw-none.json" "$SERVER_TMPL" "$out_nosnd" "$sounds_none" >/dev/null; then
    if grep -q '^AddDevice=' "$out_nosnd"; then
        miss "vanished /dev/snd still rendered an AddDevice line"
    else
        ok "vanished /dev/snd dropped by the guard"
    fi
else
    miss "vanished-/dev/snd render exited non-zero"
fi

# --- 4. USER ADDITIONS + live Image= survive a re-render ----------------

live="$tmp/out-live.container"
mk_hw "$tmp/hw-live.json" hidraw "$hid" 1
# Seed the live file from a template MISSING Timezone=local — a real
# template delta, so the re-render below must take the rewrite path
# (splice + snapshot + atomic write) instead of the byte-identical
# short-circuit, which would make every preservation assertion pass
# vacuously.
tmpl_notz="$tmp/template-notz"
grep -v '^Timezone=' "$SERVER_TMPL" >"$tmpl_notz"
render "$tmp/hw-live.json" "$tmpl_notz" "$live" "$sounds_none" >/dev/null
custom='Environment=MY_CUSTOM_VAR=42'
switched='Image=ghcr.io/dirkwa/svxlink-server:master'
# Inject an operator hand-edit + a switched channel tag into the live
# file, the way `svx channel master` + a hand edit would leave it.
CUSTOM="$custom" SWITCHED="$switched" awk '
    /^Image=/ { print ENVIRON["SWITCHED"]; next }
    /^# === BEGIN USER ADDITIONS ===/ { print; print ENVIRON["CUSTOM"]; next }
    { print }
' "$live" >"$live.edited" && mv "$live.edited" "$live"

before_snaps=$(snap_count)
if render "$tmp/hw-live.json" "$SERVER_TMPL" "$live" "$sounds_none" >/dev/null; then
    has_custom=$(grep -cxF "$custom" "$live" || true)
    has_image=$(grep -cxF "$switched" "$live" || true)
    image_lines=$(grep -c '^Image=' "$live" || true)
    default_tag=0
    grep -q '^Image=ghcr.io/dirkwa/svxlink-server:latest$' "$live" && default_tag=1
    delta_applied=0
    grep -qxF 'Timezone=local' "$live" && delta_applied=1
    if [[ "$has_custom" == 1 && "$has_image" == 1 && "$image_lines" == 1 \
          && "$default_tag" == 0 && "$delta_applied" == 1 ]]; then
        ok "USER ADDITIONS + live Image= preserved (once each) AND template delta applied"
    else
        miss "preservation wrong (custom=$has_custom image=$has_image image_lines=$image_lines default_tag=$default_tag delta=$delta_applied)"
    fi
    # The rewrite path must have snapshotted the pre-edit live file.
    if (( $(snap_count) > before_snaps )); then
        ok "re-render snapshotted the live Quadlet before overwriting"
    else
        miss "re-render overwrote the live Quadlet without a snapshot"
    fi
else
    miss "re-render exited non-zero"
fi

# --- 5. Malformed render refused, live file untouched -------------------

broken_tmpl="$tmp/broken.template"
grep -v '^Image=' "$SERVER_TMPL" >"$broken_tmpl"
before_sha=$(sha256sum "$live" | cut -d' ' -f1)
before_snaps=$(snap_count)
if render "$tmp/hw-live.json" "$broken_tmpl" "$live" "$sounds_none" >/dev/null 2>&1; then
    miss "render from an Image=-less template did not fail"
else
    ok "malformed render (no Image=) refused non-zero"
fi
broken_tmpl2="$tmp/broken2.template"
grep -v '^\[Container\]' "$SERVER_TMPL" >"$broken_tmpl2"
if render "$tmp/hw-live.json" "$broken_tmpl2" "$live" "$sounds_none" >/dev/null 2>&1; then
    miss "render from a [Container]-less template did not fail"
else
    ok "malformed render (no [Container]) refused non-zero"
fi
after_sha=$(sha256sum "$live" | cut -d' ' -f1)
if [[ "$before_sha" == "$after_sha" && "$(snap_count)" == "$before_snaps" ]]; then
    ok "refusal left the live Quadlet byte-identical, no snapshot churn"
else
    miss "refusal path touched the live Quadlet or its snapshots"
fi

# --- 6. Byte-identical re-render short-circuits -------------------------

before_sha=$(sha256sum "$live" | cut -d' ' -f1)
before_snaps=$(snap_count)
if render "$tmp/hw-live.json" "$SERVER_TMPL" "$live" "$sounds_none" >/dev/null; then
    after_sha=$(sha256sum "$live" | cut -d' ' -f1)
    # No new snapshot is the proof of the short-circuit: an "identical
    # rewrite" would still have snapshotted first.
    if [[ "$before_sha" == "$after_sha" && "$(snap_count)" == "$before_snaps" ]]; then
        ok "byte-identical re-render short-circuited (exit 0, no write, no snapshot)"
    else
        miss "no-op re-render wrote or snapshotted"
    fi
else
    miss "no-op re-render exited non-zero"
fi

# --- 7. Structural invariants of the rendered file ----------------------

if container_has_exec_or_restart "$out"; then
    miss "Exec*/Restart* key inside [Container] (Quadlet would refuse the unit)"
else
    ok "no Exec*/Restart* keys inside [Container]"
fi
if grep -qxF 'GroupAdd=keep-groups' "$out"; then
    ok "GroupAdd=keep-groups present (device access rides on host groups)"
else
    miss "GroupAdd=keep-groups missing from the render"
fi
# Anchored: comments legitimately DISCUSS UserNS=keep-id (the ADR); only
# an actual directive line is a violation.
if grep -q '^UserNS=' "$out"; then
    miss "UserNS= directive present (root-in-userns ADR violated, podman#28364)"
else
    ok "no UserNS= directive in the render"
fi

if (( fail )); then
    echo
    echo "[ERR] render-server-quadlet contract is broken — see entries above." >&2
    exit 1
fi
echo
echo "[OK] render-server-quadlet renders, guards, preserves and short-circuits correctly."
