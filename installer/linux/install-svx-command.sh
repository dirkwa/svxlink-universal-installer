#!/usr/bin/env bash
# Drops ~/.local/bin/svx — the user-facing command dispatcher.
# The dispatcher body lives in installer/linux/svx.tmpl as a real bash
# script (not a heredoc — no escaping tax, and `bash -n`/shellcheck see
# the real code), so `svx self-update` can refresh it byte-for-byte from
# GitHub Pages, where the deploy already substituted __SVX_VERSION__.
# For tree-local installs we sed the placeholder in here and chmod it.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/svx"
TEMPLATE="${HERE}/svx.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

# Embed the installer-version string so `svx version` reports something
# useful. Caller (install.sh) exports INSTALLER_VERSION.
SVX_VERSION="${INSTALLER_VERSION:-unknown}"

# Non-conflicting sed delimiter (|): INSTALLER_VERSION may contain '/'
# (e.g. branch refs in dev installs).
sed -e "s|__SVX_VERSION__|${SVX_VERSION}|g" \
    "$TEMPLATE" >"$TARGET"
chmod 0755 "$TARGET"
ok "Installed $TARGET"
