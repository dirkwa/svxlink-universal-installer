#!/usr/bin/env bash
# Tripwire for the cross-repo image contract (docs/image-contract.md in
# svxlink-images is the single source of truth).
#
# Local checks grep quadlets/svxlink-server.container.template for the
# exact contract surface the image's entrypoint consumes:
#   * Environment=SVXLINK_CONF=/etc/svxlink/svxlink.conf (the image
#     leaves SVXLINK_CONF unset so each CMD gets a per-program default;
#     this unit runs the svxlink node and must pin it),
#   * Environment=SVXLINK_LOGFILE=/var/log/svxlink/svxlink and
#     Environment=SVXLINK_LOG_MAXSIZE= (the CANONICAL names — an earlier
#     design shipped SVXLINK_LOG_FILE/SVXLINK_LOG_ROTATE_SIZE, which the
#     entrypoint silently ignored: the node fell back to stdout-only, the
#     dashboard rendered empty, and every `svx update` verify failed into
#     auto-rollback forever),
#   * no START_SVXLINK (deliberate break with f4hlv/svxlink-docker),
#   * no UserNS= directive + GroupAdd=keep-groups (root-in-userns ADR;
#     keep-id + --device + keep-groups is podman#28364),
#   * Network=host (EchoLink registers the observed UDP source; NAT
#     breaks it),
#   * ExecStartPre only after the [Service] header (Quadlet rejects
#     unknown keys per section — under [Container] the generator refuses
#     the WHOLE unit and systemctl reports "Unit not found").
#
# --remote fetches svxlink-images' raw entrypoint.sh and
# docs/image-contract.md and asserts the env names appear THERE — the
# non-self-referential half. Without it both sides of the grep live in
# this repo, which is exactly how three fatal contract drifts once
# survived review. Run from the repo root.

set -euo pipefail

TEMPLATE=${TEMPLATE:-quadlets/svxlink-server.container.template}
RAW_BASE=${SVXLINK_IMAGES_RAW_BASE:-https://raw.githubusercontent.com/dirkwa/svxlink-images/main}
CHECK_REMOTE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) CHECK_REMOTE=1 ;;
        -h|--help)
            sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[ERR] unknown flag: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] $TEMPLATE not found (run from repo root)" >&2
    exit 2
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# --- exact env lines (the entrypoint's input surface) --------------------
for line in \
    'Environment=SVXLINK_CONF=/etc/svxlink/svxlink.conf' \
    'Environment=SVXLINK_LOGFILE=/var/log/svxlink/svxlink'
do
    if grep -qxF "$line" "$TEMPLATE"; then
        ok "exact line present: $line"
    else
        miss "missing exact line: $line"
    fi
done
# MAXSIZE: the NAME is contract, the value is policy — prefix match.
if grep -q '^Environment=SVXLINK_LOG_MAXSIZE=' "$TEMPLATE"; then
    ok "Environment=SVXLINK_LOG_MAXSIZE= present"
else
    miss "Environment=SVXLINK_LOG_MAXSIZE= missing"
fi

# --- forbidden surface ----------------------------------------------------
if grep -q 'START_SVXLINK' "$TEMPLATE"; then
    miss "START_SVXLINK present — the entrypoint honors no START_* env (dead cargo at best)"
else
    ok "no START_SVXLINK anywhere"
fi
# Anchored: the template's comments legitimately DISCUSS UserNS=keep-id
# (the ADR); only a directive line is a violation.
if grep -q '^UserNS=' "$TEMPLATE"; then
    miss "UserNS= directive present (root-in-userns ADR violated)"
else
    ok "no UserNS= directive"
fi

# --- required directives --------------------------------------------------
if grep -qxF 'GroupAdd=keep-groups' "$TEMPLATE"; then
    ok "GroupAdd=keep-groups present"
else
    miss "GroupAdd=keep-groups missing"
fi
if grep -qxF 'Network=host' "$TEMPLATE"; then
    ok "Network=host present"
else
    miss "Network=host missing"
fi

# --- ExecStartPre placement ----------------------------------------------
# Track the current section header; any ExecStartPre outside [Service]
# (including before any header) makes the generator refuse the unit.
if awk '
    /^\[/ { sec = $0 }
    /^ExecStartPre/ && sec != "[Service]" { bad = 1 }
    /^ExecStartPre/ { seen = 1 }
    END { exit (bad || !seen) ? 1 : 0 }
' "$TEMPLATE"; then
    ok "ExecStartPre present and only under [Service]"
else
    miss "ExecStartPre missing, or found outside [Service]"
fi

# --- remote: the other repo actually says the same thing -------------------
if (( CHECK_REMOTE )); then
    echo
    echo "[i] fetching contract sources from $RAW_BASE"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    for f in entrypoint.sh docs/image-contract.md; do
        # -f: a 404 here must fail loudly — an unreachable contract is a
        # broken tripwire, not a pass.
        if ! curl -fsS "$RAW_BASE/$f" -o "$tmp/$(basename "$f")"; then
            miss "could not fetch $RAW_BASE/$f"
        fi
    done
    if [[ -s "$tmp/entrypoint.sh" && -s "$tmp/image-contract.md" ]]; then
        for name in SVXLINK_CONF SVXLINK_LOGFILE SVXLINK_LOG_MAXSIZE; do
            if grep -q "$name" "$tmp/entrypoint.sh"; then
                ok "entrypoint.sh consumes $name"
            else
                miss "entrypoint.sh does not mention $name — env contract drifted"
            fi
            if grep -q "$name" "$tmp/image-contract.md"; then
                ok "image-contract.md documents $name"
            else
                miss "image-contract.md does not mention $name"
            fi
        done
        # The image name our template pulls must be the one the contract
        # publishes (the reviewer's finding #1 class: svxlink vs
        # svxlink-server 404s the very first pull).
        img=$(sed -n 's/^Image=\(ghcr\.io\/[^:@]*\).*/\1/p' "$TEMPLATE" | head -1)
        if [[ -n "$img" ]] && grep -qF "$img" "$tmp/image-contract.md"; then
            ok "image name $img appears in the contract doc"
        else
            miss "image name '$img' not found in the contract doc"
        fi
    fi
fi

if (( fail )); then
    echo
    echo "[ERR] image contract drift — see entries above (and svxlink-images/docs/image-contract.md)." >&2
    exit 1
fi
echo
echo "[OK] quadlet template matches the image contract."
