#!/usr/bin/env bash
# Standalone uninstaller — same semantics as `svx uninstall`, kept as a
# separate script so a broken or deleted ~/.local/bin/svx can never take
# the uninstall path down with it. PRESERVES user data (~/.svxlink: config,
# logs, snapshots, hardware.json) and the pulled server images (rollback
# material). To purge those, run the commands printed at the end.

set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
USER_UNIT_DIR="${HOME}/.config/systemd/user"
# svxlink-dashboard is opt-in; all loops below tolerate a missing
# unit/quadlet/container.
UNITS=(svxlink-server svxlink-dashboard)

echo "Stopping svxlink-* units..."
for u in "${UNITS[@]}"; do
    # `stop`, not `disable --now`: Quadlet-generated units are transient
    # from systemd's point of view — removing the .container file below IS
    # the durable disable.
    systemctl --user stop "${u}.service" 2>/dev/null || true
done

echo "Removing Quadlet files..."
for u in "${UNITS[@]}"; do
    rm -f "$QUADLET_DIR/${u}.container"
done

echo "Removing podman containers..."
for u in "${UNITS[@]}"; do
    if podman container exists "$u" 2>/dev/null; then
        podman rm -f "$u" 2>/dev/null || true
    fi
done

# The dashboard image only ever exists locally (never pushed — license);
# removing it is safe: `svx dashboard install` rebuilds it from
# ~/.svxlink/dashboard-src, which is preserved.
podman rmi localhost/svxlink-dashboard:local 2>/dev/null || true

# resolv-watch trio (only present if `svx resolv-watch` was ever run).
systemctl --user disable --now svxlink-resolv-watch.path 2>/dev/null || true
systemctl --user stop svxlink-resolv-watch.service 2>/dev/null || true
rm -f "$USER_UNIT_DIR/svxlink-resolv-watch.path" \
      "$USER_UNIT_DIR/svxlink-resolv-watch.service"

systemctl --user daemon-reload || true

echo
echo "Preserved (intentional):"
echo "  ~/.svxlink/                          — svxlink config, logs, sounds,"
echo "                                         snapshots, hardware.json, payload"
echo "  ghcr.io/dirkwa/svxlink-server images — kept for rollback / reinstall"
echo "  ~/.local/bin/{svx,svx-recovery}      — CLI + host recovery script"
echo "  /usr/local/bin/svx                   — symlink to the CLI"
echo "  /etc/udev/rules.d/99-svxlink-ptt.rules    — PTT device rule (root-owned)"
echo "  /etc/systemd/journald.conf.d/svxlink.conf — journald retention (root-owned)"
echo
echo "To purge ALL data, run:"
echo "  rm -rf ~/.svxlink"
echo "  rm -f ~/.local/bin/svx ~/.local/bin/svx-recovery"
echo "  sudo rm -f /usr/local/bin/svx /etc/udev/rules.d/99-svxlink-ptt.rules \\"
echo "             /etc/systemd/journald.conf.d/svxlink.conf"
echo "  podman rmi -f \$(podman images -q ghcr.io/dirkwa/svxlink-server) 2>/dev/null"
echo "Done."
