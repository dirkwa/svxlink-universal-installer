#!/usr/bin/env bash
# Shared merge that carries operator hardware choices forward across a
# re-detect. Sourced by the wizard paths (`svx audio` / `svx ptt` in
# svx.tmpl, and install.sh's hardware step) and by
# scripts/test/check-hardware-merge.sh, so the production filter and its
# test can never drift apart — the filter lives HERE and only here.
#
# detect-hardware.sh always re-emits fresh defaults — audio rx/tx pointed
# at the first ALSA card, ptt.type=none, squelch VOX,
# hostAudioMitigation=none — so a documented re-run (`curl … | bash`, or a
# later wizard pass) would silently reset the operator's confirmed picks:
# the chosen RX/TX cards, the PTT wiring, the squelch mode, and the
# PipeWire/Pulse mitigation answer (which gates a re-prompt). This merge
# carries those operator sections forward over the fresh detection.
#
# Two rules, both deliberate:
#
#   1. Operator sections (audio, ptt, squelch) are carried with explicit
#      has() checks, NEVER `//`. jq's `//` treats stored `false`/`null` as
#      empty: an operator's `ptt.invert=false` or an intentionally-null
#      audio pick would fall through to the fresh default and silently
#      resurrect — the exact bug class the signalk reference documents for
#      its audio.enabled toggle. has() carries the stored value verbatim
#      when the section exists, whatever that value is.
#
#   2. Inventory sections (serial[], gpio) always take the FRESH values:
#      the attached device set may have changed between runs (adapter
#      unplugged, Pi model swap), and stale inventory is what produces
#      AddDevice= lines pointing at vanished nodes. Because the filter
#      starts from the fresh document and only overwrites the carried
#      keys, this rule — and dropping any stale informational extras the
#      old file may hold (cards[]/hidraw[] candidate lists, detectedAt) —
#      needs no code at all.
#
# hardware_merge <old.json> <fresh.json> — prints merged JSON to stdout.
# Requires jq; callers guard on `command -v jq` before invoking (the
# jq-less install path never re-merges — it only writes the fresh file
# when none exists, so nothing can be lost).
hardware_merge() {
    jq -s '
        .[0] as $old
        | .[1]
        | .audio   = (if $old | has("audio")   then $old.audio   else .audio   end)
        | .ptt     = (if $old | has("ptt")     then $old.ptt     else .ptt     end)
        | .squelch = (if $old | has("squelch") then $old.squelch else .squelch end)
        # hostAudioMitigation lives inside audio, so the audio carry above
        # normally brings it along. This backstop covers a legacy
        # hardware.json written before the key existed: without it the key
        # would vanish from the merged file and the wizard would lose its
        # "already answered" marker and re-prompt. `// {}` first — a null
        # audio (no cards detected, never configured) has no keys and
        # has() on null is a jq error.
        | .audio = ((.audio // {})
            | if has("hostAudioMitigation") then .
              else . + {hostAudioMitigation: "none"} end)
    ' "$1" "$2"
}
