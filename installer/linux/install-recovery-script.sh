#!/usr/bin/env bash
# Drops ~/.local/bin/svx-recovery — the SSH-only safety net. Pure bash,
# zero containers required: it can restore quadlets from
# ~/.svxlink/snapshots/ and kick systemd into reloading them even when
# podman itself is broken.
#
# The recovery body lives in installer/linux/svx-recovery.tmpl as a real
# bash script. Verbatim copy here — no placeholders to substitute,
# unlike the svx dispatcher which embeds INSTALLER_VERSION.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/svx-recovery"
TEMPLATE="${HERE}/svx-recovery.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

cp "$TEMPLATE" "$TARGET"
chmod 0755 "$TARGET"
ok "svx-recovery installed at $TARGET"
