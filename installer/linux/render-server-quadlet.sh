#!/usr/bin/env bash
# Render the LIVE svxlink-server Quadlet from the staged template +
# ~/.svxlink/hardware.json, preserving what the operator owns in the live
# file. Combines the two halves of the signalk reference (the
# fenced-block renderer render-server-quadlet.sh + the live-splice /
# snapshot / atomic-write logic of `signalk render-server`) into ONE
# script so install.sh and `svx render-server` cannot drift.
#
# Interface (all env-overridable; no positional args):
#   HARDWARE_JSON  hardware description   (default ~/.svxlink/hardware.json)
#   TEMPLATE       pristine template      (default ~/.svxlink/payload/svxlink-server.container.template)
#   OUTPUT         live Quadlet to write  (default ~/.config/containers/systemd/svxlink-server.container)
#   SNAPSHOT_DIR   pre-overwrite backups  (default ~/.svxlink/snapshots)
#   SND_DIR        ALSA device dir        (default /dev/snd)
#   SOUNDS_DIR     per-lang overrides     (default ~/.svxlink/sounds)
# SND_DIR/SOUNDS_DIR (and pointing HARDWARE_JSON/TEMPLATE/OUTPUT at
# fixtures) exist purely so scripts/test/check-render-quadlet.sh can seed
# present/absent nodes deterministically without touching the host.
#
# Behavior: render TEMPLATE with the HARDWARE fenced block rebuilt from
# HARDWARE_JSON; if OUTPUT already exists, splice its live Image= line and
# USER ADDITIONS inner lines into the render; short-circuit when the
# result is byte-identical; otherwise snapshot OUTPUT and atomically
# replace it. Exit 0 on success (including the nothing-to-do case).
# Caller owns daemon-reload/restart — this script never touches systemd.

set -euo pipefail

HARDWARE_JSON="${HARDWARE_JSON:-${HOME}/.svxlink/hardware.json}"
TEMPLATE="${TEMPLATE:-${HOME}/.svxlink/payload/svxlink-server.container.template}"
OUTPUT="${OUTPUT:-${HOME}/.config/containers/systemd/svxlink-server.container}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${HOME}/.svxlink/snapshots}"
SND_DIR="${SND_DIR:-/dev/snd}"
SOUNDS_DIR="${SOUNDS_DIR:-${HOME}/.svxlink/sounds}"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] render-server-quadlet: template not found: $TEMPLATE" >&2
    exit 1
fi
if [[ ! -f "$HARDWARE_JSON" ]]; then
    echo "[ERR] render-server-quadlet: hardware.json not found: $HARDWARE_JSON" >&2
    exit 1
fi

# Drop AddDevice= lines whose device node is absent at render time.
# hardware.json records what the wizard confirmed at CONFIG time, but a
# device can disappear between then and render — a CM108 unplugged, a
# serial adapter that drops its by-id symlink while it re-enumerates, a
# host that lost its sound card. An AddDevice= pointing at a path podman
# can't stat fails container creation hard (exit 125) BEFORE svxlink
# starts, so one absent device crashloops the whole node. Emit the line
# only when the source exists, otherwise silently drop it (the node still
# starts; that one input is just absent) rather than bricking. Unlike the
# signalk reference (serial-only guard, because its CAN lines were not
# /dev nodes) EVERY AddDevice source here IS a /dev path, so all of them
# are guarded. Volume= and every other line pass through untouched.
# Reads stdin, writes stdout.
guard_adddevice() {
    local line dev
    while IFS= read -r line; do
        case "$line" in
            "AddDevice="*)
                # Strip the "AddDevice=" prefix, then any ":perms" suffix
                # (e.g. AddDevice=/dev/foo:rwm) to get the host path to stat.
                dev=${line#AddDevice=}
                dev=${dev%%:*}
                # Explicit if, not `[ -e ] && printf`: the guard runs in a
                # `... | guard_adddevice` pipe under set -euo pipefail, and a
                # short-circuited && leaves the loop (and the function) with
                # status 1 on a skipped device — the very case this exists to
                # handle — which would abort rendering. An if makes the skip a
                # success.
                if [ -e "$dev" ]; then
                    printf '%s\n' "$line"
                fi
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done
}

# Build the AddDevice/Volume block from hardware.json + the sounds dir.
# jq if present (best); otherwise a grep/sed fallback that handles the
# narrow pretty-printed shape detect-hardware.sh emits (documented below).
hardware_block() {
    local audio_configured=false ptt_type="none" ptt_dev="" gpio_chip=""

    if command -v jq >/dev/null 2>&1; then
        # Audio is "configured" when either direction has a device string.
        # A hardware.json with rx/tx null (no ALSA card at detect time)
        # must NOT emit AddDevice=/dev/snd — the mount would be pointless
        # and, on a truly soundless host, /dev/snd may not even exist.
        local rx tx
        rx=$(jq -r '.audio.rx.dev // ""' "$HARDWARE_JSON")
        tx=$(jq -r '.audio.tx.dev // ""' "$HARDWARE_JSON")
        [[ -n "$rx" || -n "$tx" ]] && audio_configured=true
        ptt_type=$(jq -r '.ptt.type // "none"' "$HARDWARE_JSON")
        ptt_dev=$(jq -r '.ptt.device // ""' "$HARDWARE_JSON")
        gpio_chip=$(jq -r '.gpio.chips[0] // ""' "$HARDWARE_JSON")
    else
        # jq-less fallback — same minimal-parser spirit as the signalk
        # serial-only fallback. Relies on detect-hardware.sh's
        # pretty-printed one-key-per-line output: section-scope with a sed
        # range (/"ptt"/ to the first closing brace), then extract flat
        # string values. Good enough for the seed/render happy path on a
        # host where the optional jq install failed; wizard edits require
        # jq anyway (hardware_merge does).
        grep -q '"dev"[[:space:]]*:[[:space:]]*"alsa:' "$HARDWARE_JSON" \
            && audio_configured=true
        local ptt_json
        ptt_json=$(sed -n '/"ptt"[[:space:]]*:/,/}/p' "$HARDWARE_JSON")
        ptt_type=$(printf '%s\n' "$ptt_json" \
            | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        ptt_type=${ptt_type:-none}
        ptt_dev=$(printf '%s\n' "$ptt_json" \
            | sed -n 's/.*"device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        # First entry of gpio.chips[]: scope to the "chips" array, take the
        # first quoted string that isn't the key itself. Deliberately NOT
        # anchored on a literal /dev/gpiochip prefix — tests point the
        # probe roots at fixture paths, and production paths match anyway.
        gpio_chip=$(sed -n '/"chips"[[:space:]]*:/,/\]/p' "$HARDWARE_JSON" \
            | grep -o '"[^"]*"' | grep -v '"chips"' | head -1 | tr -d '"')
    fi

    {
        # Whole /dev/snd dir, not individual pcm/control nodes: child
        # nodes are recreated on USB replug and per-node AddDevice lines
        # would go stale; the dir survives.
        if [[ "$audio_configured" == true ]]; then
            echo "AddDevice=${SND_DIR}"
        fi

        case "$ptt_type" in
            hidraw|serial)
                # hidraw: the udev rule's stable /dev/svxlink-ptt symlink;
                # serial: a /dev/serial/by-id path. Both resolve at
                # container start — a replug needs `svx restart`.
                [[ -n "$ptt_dev" ]] && echo "AddDevice=${ptt_dev}"
                ;;
            gpiod)
                # For gpiod PTT the wizard stores the CHIP path in
                # ptt.device (/dev/gpiochipN — the line number lives in
                # ptt.pin and svxlink.conf, not here). Older/hand-edited
                # files may leave device empty; fall back to the first
                # detected chip so the render still works. No pattern
                # check on the path — the [ -e ] guard below drops
                # anything that doesn't exist.
                if [[ -n "$ptt_dev" ]]; then
                    echo "AddDevice=${ptt_dev}"
                elif [[ -n "$gpio_chip" ]]; then
                    echo "AddDevice=${gpio_chip}"
                fi
                ;;
        esac
    } | guard_adddevice

    # One read-only shadow mount per existing language-pack override dir.
    # NEVER the whole sounds/ tree — mounting /usr/share/svxlink/sounds
    # wholesale would hide the image's baked en_US pack (the f4hlv
    # mistake); per-language mounts let a German pack add de_DE while the
    # baked en_US stays available as fallback. [ -d ] guarded inherently:
    # only dirs that exist are iterated, so a removed pack can't brick the
    # unit (a Volume= with a missing source fails container create with
    # exit 125 before svxlink starts).
    local langdir lang
    for langdir in "$SOUNDS_DIR"/*/; do
        [[ -d "$langdir" ]] || continue
        lang=$(basename "$langdir")
        echo "Volume=${SOUNDS_DIR}/${lang}:/usr/share/svxlink/sounds/${lang}:ro"
    done
}

# --- render: replace the HARDWARE fenced block -------------------------
rendered=$(awk -v hw_block="$(hardware_block)" '
    BEGIN { in_hw = 0 }
    /^# === BEGIN HARDWARE/ { print; if (hw_block != "") print hw_block; in_hw = 1; next }
    /^# === END HARDWARE/   { in_hw = 0; print; next }
    !in_hw                  { print }
' "$TEMPLATE")

# Never install junk over a working Quadlet (or as a fresh one). A
# renderer path that exits 0 but emits empty/truncated output (malformed
# hardware.json, a future bug that short-circuits) would otherwise be
# snapshotted over the live file — taking the repeater down. Require the
# two structural anchors every valid render has: the [Container] section
# header line and an Image= line. Cheap, and it fails BEFORE the
# snapshot/write path.
if [[ -z "$rendered" ]] || ! grep -q '^\[Container\]' <<<"$rendered" \
    || ! grep -q '^Image=' <<<"$rendered"; then
    echo "[ERR] render produced empty or malformed output (no [Container]/Image=)" >&2
    echo "      — refusing to touch $OUTPUT." >&2
    exit 1
fi

if [[ -f "$OUTPUT" ]]; then
    # Preserve the running IMAGE tag. The template pins Image=…:latest,
    # but `svx channel` / auto-rollback rewrite this line in the LIVE
    # Quadlet — it is the operator's channel-of-record. Rendering from
    # the pristine template would silently revert that choice on every
    # re-render. Only when both sides have one; if the live file somehow
    # lacks it we keep the template's rather than drop it.
    live_image=$(grep -m1 '^Image=' "$OUTPUT" || true)
    if [[ -n "$live_image" ]]; then
        # Replace only the FIRST Image= line in the render with the live
        # one. Env-passed awk (never sed) so a tag with sed-special chars
        # (a @sha256: digest pin, say) can't corrupt the program text.
        rendered=$(LIVE_IMAGE="$live_image" awk '
            !done && /^Image=/ { print ENVIRON["LIVE_IMAGE"]; done = 1; next }
            { print }
        ' <<<"$rendered")
    fi

    # Preserve the operator's hand-edits between the USER ADDITIONS
    # markers. A fresh render comes from the pristine template, so
    # without this splice a routine re-render would silently wipe custom
    # mounts/env the operator added to the live file. If either side
    # lacks the markers we leave the render as-is: nothing to preserve,
    # or a template that no longer carries the block. awk + ENVIRON[]
    # (never sed) so arbitrary operator content — quotes, %, & — can't
    # be reinterpreted as program text.
    begin_marker='# === BEGIN USER ADDITIONS ==='
    end_marker='# === END USER ADDITIONS ==='
    if grep -qF "$begin_marker" "$OUTPUT" && grep -qF "$end_marker" "$OUTPUT" \
        && grep -qF "$begin_marker" <<<"$rendered" \
        && grep -qF "$end_marker" <<<"$rendered"; then
        live_additions=$(awk '
            /^# === BEGIN USER ADDITIONS ===/ { grab = 1; next }
            /^# === END USER ADDITIONS ===/   { grab = 0 }
            grab { print }
        ' "$OUTPUT")
        rendered=$(LIVE_ADDITIONS="$live_additions" awk '
            /^# === BEGIN USER ADDITIONS ===/ {
                print
                add = ENVIRON["LIVE_ADDITIONS"]
                if (add != "") print add
                skip = 1
                next
            }
            /^# === END USER ADDITIONS ===/ { skip = 0; print; next }
            skip { next }
            { print }
        ' <<<"$rendered")
    fi

    # Idempotent short-circuit: byte-identical render means nothing to
    # write and no reason for the caller to restart the data plane.
    # $(cat) strips the file's trailing newline, matching how the
    # command-substituted render lost its own — and the atomic write
    # below re-appends exactly one.
    if [[ "$rendered" == "$(cat "$OUTPUT")" ]]; then
        echo "[OK] $OUTPUT already matches the current template + hardware — nothing to do."
        exit 0
    fi

    # Snapshot before overwrite — the raw material `svx recover
    # rollback-server` restores. Refuse to proceed without a backup.
    mkdir -p "$SNAPSHOT_DIR"
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    snap="${SNAPSHOT_DIR}/${ts}-$(basename "$OUTPUT")"
    if cp -p "$OUTPUT" "$snap"; then
        echo "[i] Snapshotted the current Quadlet to $snap"
    else
        echo "[ERR] Could not snapshot $OUTPUT — refusing to overwrite without a backup." >&2
        exit 1
    fi
fi

# Atomic write: mktemp sibling (same filesystem, so mv is atomic) +
# chmod 0644 + mv. Handle the write/chmod failing (ENOSPC, EDQUOT)
# explicitly: without this, set -e would abort before the mv and leave
# the temp file behind in the live Quadlet dir.
mkdir -p "$(dirname "$OUTPUT")"
tmp=$(mktemp "${OUTPUT}.XXXXXX") || {
    echo "[ERR] mktemp failed for $OUTPUT" >&2
    exit 1
}
if ! printf '%s\n' "$rendered" >"$tmp" || ! chmod 0644 "$tmp"; then
    echo "[ERR] Failed to stage the rendered Quadlet at $tmp." >&2
    rm -f "$tmp"
    exit 1
fi
if ! mv -f "$tmp" "$OUTPUT"; then
    echo "[ERR] Failed to install rendered Quadlet to $OUTPUT." >&2
    rm -f "$tmp"
    exit 1
fi
echo "[OK] Wrote $OUTPUT."
echo "[i] Apply with: systemctl --user daemon-reload && systemctl --user restart svxlink-server.service"
