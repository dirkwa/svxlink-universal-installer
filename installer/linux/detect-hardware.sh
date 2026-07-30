#!/usr/bin/env bash
# Pure hardware detection for the svx wizard. Emits hardware.json on stdout:
# ALSA cards, CM108-family hidraw PTT candidates, USB serial adapters, GPIO
# chips, Pi model. Detection only PROPOSES — wizard-confirmed values are
# OperatorIntent, carried across re-detects by lib/hardware-merge.sh. This
# script must therefore stay side-effect free and always emit the same
# fresh-default shape (ptt.type=none, squelch VOX) no matter what the
# operator configured before; the merge is what preserves their choices.
#
# Contract keys (pinned schema, consumed by render-server-quadlet.sh and
# hardware-merge.sh): audio{rx,tx,hostAudioMitigation}, ptt, squelch,
# serial[], gpio{model,chips}. The extra top-level keys (detectedAt,
# cards[], hidraw[]) are informational candidate lists for the wizard's
# pickers and bug reports; hardware_merge starts from the fresh document,
# so they always reflect the latest probe and are never carried stale.
#
# Requires NO external tools beyond coreutils — JSON is emitted via printf
# (jq-less hosts must still be able to run the wizard's happy path).
#
# Probe roots are env-overridable PURELY so scripts/test/check-*.sh can
# seed present/absent hardware deterministically without touching the
# host's /proc, /sys, or /dev. Production always uses the defaults.
set -euo pipefail

PROC_ASOUND="${PROC_ASOUND:-/proc/asound}"
HIDRAW_SYS="${HIDRAW_SYS:-/sys/class/hidraw}"
SERIAL_DIR="${SERIAL_DIR:-/dev/serial/by-id}"
GPIOCHIP_GLOB="${GPIOCHIP_GLOB:-/dev/gpiochip*}"
DT_MODEL="${DT_MODEL:-/proc/device-tree/model}"

# Minimal JSON string escaping (backslash, double quote, control chars are
# not expected in kernel-provided names, but a display string from a USB
# descriptor is attacker^Wvendor-controlled text — cheap to be correct).
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

emit_json() {
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # --- ALSA cards ------------------------------------------------------
    # Order comes from $PROC_ASOUND/cards (kernel enumeration order); the
    # NAME comes from $PROC_ASOUND/card<N>/id. Devices are always addressed
    # by CARD=<id>, never by index: USB card numbering shifts across boots
    # (a replugged CM108 that was card 1 comes back as card 2), while the
    # id string is stable. plughw (not raw hw:) so ALSA converts between
    # svxlink's internal 16 kHz and the card's native rate.
    local card_items=()
    local first_card=""
    if [[ -r "$PROC_ASOUND/cards" ]]; then
        local line idx id name id_file
        while IFS= read -r line; do
            # Card header lines look like:
            #  0 [Device         ]: USB-Audio - USB Audio Device
            # (continuation lines are indented description text — skipped
            # by the pattern match on the "<n> [" prefix).
            [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+\[([^]]*)\]:[[:space:]]*(.*)$ ]] || continue
            idx="${BASH_REMATCH[1]}"
            # Prefer card<N>/id (the exact string ALSA matches CARD= on);
            # fall back to the bracket field with its padding trimmed.
            id_file="$PROC_ASOUND/card${idx}/id"
            if [[ -r "$id_file" ]]; then
                id=$(<"$id_file")
            else
                id="${BASH_REMATCH[2]}"
                id="${id%"${id##*[![:space:]]}"}"   # rtrim
            fi
            name="${BASH_REMATCH[3]}"
            card_items+=("{\"index\":${idx},\"card\":\"$(json_escape "$id")\",\"name\":\"$(json_escape "$name")\"}")
            [[ -z "$first_card" ]] && first_card="$id"
        done <"$PROC_ASOUND/cards"
    fi

    # Default rx/tx = the first detected card (single-USB-soundcard nodes —
    # the overwhelmingly common case — need zero wizard interaction for
    # audio). Two-card setups pick per-direction in `svx audio`.
    local rx_json="null" tx_json="null"
    if [[ -n "$first_card" ]]; then
        local esc dev
        esc=$(json_escape "$first_card")
        dev="alsa:plughw:CARD=${esc},DEV=0"
        rx_json="{\"card\":\"${esc}\",\"dev\":\"${dev}\",\"sampleRate\":48000}"
        tx_json="$rx_json"
    fi

    # --- CM108-family hidraw PTT candidates ------------------------------
    # A CM108/CM119's GPIO pins (the classic sound-card-PTT hack) surface
    # as a hidraw node. Match C-Media by the HID_ID vendor field in the
    # device uevent: HID_ID=0003:00000D8C:0000013C (bus:vendor:product,
    # zero-padded hex). Vendor 0D8C = C-Media. The /dev node is derived
    # from the sysfs directory name — hidraw class dirs are named exactly
    # like their device nodes.
    local hidraw_items=()
    local hdir uevent hid_id hid_name node
    for hdir in "$HIDRAW_SYS"/*; do
        [[ -e "$hdir" ]] || continue
        uevent="$hdir/device/uevent"
        [[ -r "$uevent" ]] || continue
        hid_id=$(sed -n 's/^HID_ID=//p' "$uevent" | head -1)
        # The vendor field is 8 zero-padded hex digits: 00000D8C. Anchor on
        # the surrounding colons so a product id that happens to contain
        # d8c can never match; -i because the kernel prints uppercase but
        # fixture files might not.
        printf '%s' "$hid_id" | grep -qiE ':00000d8c:' || continue
        hid_name=$(sed -n 's/^HID_NAME=//p' "$uevent" | head -1)
        node="/dev/$(basename "$hdir")"
        hidraw_items+=("{\"node\":\"$(json_escape "$node")\",\"name\":\"$(json_escape "$hid_name")\",\"hidId\":\"$(json_escape "$hid_id")\"}")
    done

    # --- USB serial via /dev/serial/by-id --------------------------------
    # by-id symlinks are stable across renumbering (ttyUSB0 -> ttyUSB1 on
    # replug); the PTT wizard must never store a raw ttyUSB path. Default
    # enabled=false: serial adapters on a repeater host are usually CAT or
    # telemetry, not PTT — passthrough is opt-in via the wizard.
    local serial_items=()
    local link
    for link in "$SERIAL_DIR"/*; do
        [[ -e "$link" ]] || continue
        serial_items+=("{\"byId\":\"$(json_escape "$link")\",\"enabled\":false}")
    done

    # --- GPIO chips + Pi model -------------------------------------------
    # gpiod chips only (/dev/gpiochip*) — the sysfs GPIO interface is
    # effectively unusable rootless and is not offered. Word-split the
    # glob deliberately so tests can point GPIOCHIP_GLOB at a fixture dir.
    local gpio_chips=()
    local chip
    # shellcheck disable=SC2206 # unquoted on purpose: GPIOCHIP_GLOB must glob-expand
    local chip_candidates=($GPIOCHIP_GLOB)
    for chip in "${chip_candidates[@]}"; do
        [[ -e "$chip" ]] || continue
        gpio_chips+=("\"$(json_escape "$chip")\"")
    done

    local gpio_model="none"
    if [[ -r "$DT_MODEL" ]]; then
        local model
        # device-tree strings are NUL-terminated; strip it or the value
        # poisons downstream printf/grep.
        model=$(tr -d '\0' <"$DT_MODEL" 2>/dev/null || echo "")
        if [[ "$model" =~ [Rr]aspberry ]]; then
            if [[ "$model" =~ Pi[[:space:]]*5 ]]; then gpio_model="rpi5"
            elif [[ "$model" =~ Pi[[:space:]]*4 ]]; then gpio_model="rpi4"
            elif [[ "$model" =~ Pi[[:space:]]*3 ]]; then gpio_model="rpi3"
            else gpio_model="rpi-other"; fi
        fi
    fi

    # --- emit ------------------------------------------------------------
    join_items() {
        # join_items ITEM... — comma-join pre-rendered JSON fragments with
        # 4-space indentation, or emit nothing for an empty list. Callers
        # pass "${arr[@]:-}", which under `set -u` expands an EMPTY array
        # to a single empty string — skip those so an empty list renders
        # as [] and not as one blank element.
        local first=1 item
        for item in "$@"; do
            [[ -z "$item" ]] && continue
            if (( first )); then first=0; else printf ',\n'; fi
            printf '    %s' "$item"
        done
        (( first )) || printf '\n'
    }

    printf '{\n'
    printf '  "detectedAt": "%s",\n' "$now"
    printf '  "audio": {\n'
    printf '    "rx": %s,\n' "$rx_json"
    printf '    "tx": %s,\n' "$tx_json"
    printf '    "hostAudioMitigation": "none"\n'
    printf '  },\n'
    printf '  "ptt": {\n'
    printf '    "type": "none",\n'
    printf '    "device": "",\n'
    printf '    "pin": "",\n'
    printf '    "invert": false\n'
    printf '  },\n'
    printf '  "squelch": {\n'
    printf '    "type": "VOX"\n'
    printf '  },\n'
    printf '  "cards": [\n'
    join_items "${card_items[@]:-}"
    printf '  ],\n'
    printf '  "hidraw": [\n'
    join_items "${hidraw_items[@]:-}"
    printf '  ],\n'
    printf '  "serial": [\n'
    join_items "${serial_items[@]:-}"
    printf '  ],\n'
    printf '  "gpio": {\n'
    printf '    "model": "%s",\n' "$gpio_model"
    printf '    "chips": [\n'
    join_items "${gpio_chips[@]:-}"
    printf '    ]\n'
    printf '  }\n'
    printf '}\n'
}

emit_json
