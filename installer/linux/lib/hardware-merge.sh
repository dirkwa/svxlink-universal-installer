#!/usr/bin/env bash
# Shared merge that carries operator hardware choices forward across a
# re-detect. Sourced by the wizard paths (`svx audio` / `svx ptt` in
# svx.tmpl, and install.sh's hardware step) and by
# scripts/test/check-hardware-merge.sh, so the production filter and its
# test can never drift apart — the filter lives HERE and only here.
#
# detect-hardware.sh always re-emits fresh defaults, so a documented
# re-run (`curl … | bash`, or a later wizard pass) would silently reset
# the operator's confirmed picks: the PTT wiring, the squelch mode, and
# the PipeWire/Pulse mitigation answer (which gates a re-prompt). This
# merge carries those operator sections forward over the fresh detection.
#
# Three rules, all deliberate:
#
#   1. Operator sections (ptt, squelch, audio.hostAudioMitigation) are
#      carried with explicit has() checks, NEVER `//`. jq's `//` treats
#      stored `false`/`null` as empty: an operator's `ptt.invert=false`
#      would fall through to the fresh default and silently resurrect —
#      the exact bug class the signalk reference documents for its
#      audio.enabled toggle. has() carries the stored value verbatim
#      when the section exists, whatever that value is.
#
#   2. audio.rx/tx ALWAYS take the FRESH detection values. An earlier
#      revision carried the whole audio section — but hardware.json's
#      audio is DETECTION output, not OperatorIntent, and carrying it
#      froze the first run's proposal forever: on the Pi 4 the original
#      (pre-capture-fix) detection had proposed the onboard bcm2835 for
#      tx, and the merge then overrode every corrected re-detect with
#      that stale value, defeating the install-time parking. The
#      operator's REAL audio choice lives in svxlink.conf (the wizard
#      writes AUDIO_DEV there); hardware.json audio only drives the
#      AddDevice render and install-time defaults, and for both, current
#      truth beats history. Bonus: unplugging the USB interface and
#      re-running the installer now parks the node instead of
#      crashlooping it.
#
#   3. Inventory sections (serial[], gpio) always take the FRESH values:
#      the attached device set may have changed between runs (adapter
#      unplugged, Pi model swap), and stale inventory is what produces
#      AddDevice= lines pointing at vanished nodes. Because the filter
#      starts from the fresh document and only overwrites the carried
#      keys, this rule — and dropping any stale informational extras the
#      old file may hold (cards[]/hidraw[] candidate lists, detectedAt)
#      — needs no code at all.
#
# hardware_merge <old.json> <fresh.json> — prints merged JSON to stdout.
# Requires jq; callers guard on `command -v jq` before invoking (the
# jq-less install path never re-merges — it only writes the fresh file
# when none exists, so nothing can be lost).
hardware_merge() {
    jq -s '
        .[0] as $old
        | .[1]
        | .ptt     = (if $old | has("ptt")     then $old.ptt     else .ptt     end)
        | .squelch = (if $old | has("squelch") then $old.squelch else .squelch end)
        # audio.rx/tx stay FRESH (rule 2); only the operator-GIVEN
        # mitigation answer is carried. `// {}` guards both sides: a
        # legacy old file may hold audio:null, and has() on null is a jq
        # error.
        | .audio = ((.audio // {})
            + {hostAudioMitigation:
                (if (($old.audio // {}) | has("hostAudioMitigation"))
                 then $old.audio.hostAudioMitigation
                 elif ((.audio // {}) | has("hostAudioMitigation"))
                 then (.audio // {}).hostAudioMitigation
                 else "none" end)})
    ' "$1" "$2"
}
