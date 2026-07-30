#!/usr/bin/env bash
# Post-install standalone health check. Probes the running stack without
# touching it. Safe to run any time. Coarser than `svx health` (which adds
# in-container pgrep and restart-scoped log-growth checks) but has zero
# dependencies on the svx CLI being installed or intact.

set -euo pipefail

SVX_HOME="${HOME}/.svxlink"
QUADLET_DIR="${HOME}/.config/containers/systemd"
LOG_FILE="${SVX_HOME}/log/svxlink"

# The dashboard's published port is install-time-configurable (default
# 8080). Read it from the rendered Quadlet's PublishPort= line so this
# standalone probe hits the right port without the operator exporting
# anything; the bind address prefix (0.0.0.0 or 127.0.0.1) is skipped by
# the pattern. 127.0.0.1 always reaches a published port regardless of
# the configured bind.
dash_port() {
    local q="${QUADLET_DIR}/svxlink-dashboard.container"
    local p
    # `|| true`: a missing Quadlet makes sed exit 2 (pipefail propagates
    # it); keep the ${p:-8080} fallback reachable regardless of call site.
    p=$(sed -n 's/^PublishPort=[^:]*:\([0-9][0-9]*\):80.*/\1/p' "$q" 2>/dev/null | head -1 || true)
    printf '%s' "${p:-8080}"
}

echo "=== SvxLink Stack Doctor ==="

echo
echo "=== systemd-user units ==="
systemctl --user --no-pager list-units --all 'svxlink-*' 2>/dev/null || true

echo
echo "=== Container snapshot ==="
podman ps -a --filter 'name=svxlink-' --format '{{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true

# Log file: svxlink has no HTTP surface, so the log file IS the primary
# liveness record — but its AGE is [INFO] only, never a failure: an idle
# repeater legitimately logs nothing for hours (the image contract's
# health section says the same). Only restart-scoped growth checks (in
# `svx health` / `svx update`) may gate on log output, because startup
# banners guarantee some.
echo
echo "=== SvxLink log file ==="
if [[ -f "$LOG_FILE" ]]; then
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo "?")
    mtime=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    printf '  [OK]   %s (%s bytes)\n' "$LOG_FILE" "$size"
    printf '  [INFO] last log activity: %dh %dm ago (idle nodes log nothing for hours — not a failure)\n' \
        $(( age / 3600 )) $(( age % 3600 / 60 ))
    [[ -f "${LOG_FILE}.1" ]] && printf '  [INFO] rotation sibling present: %s\n' "${LOG_FILE}.1"
else
    echo "  [FAIL] $LOG_FILE missing — the server container has never"
    echo "         reached file-mode logging (check: podman logs svxlink-server)"
fi

# Dashboard: only probe when the operator actually installed it (the
# quadlet's presence is the durable record of that opt-in).
if [[ -f "${QUADLET_DIR}/svxlink-dashboard.container" ]]; then
    echo
    echo "=== Dashboard ==="
    port=$(dash_port)
    url="http://127.0.0.1:${port}/"
    if curl -fsS -o /dev/null -m 5 "$url"; then
        printf '  [OK]   dashboard answering at %s\n' "$url"
    else
        printf '  [FAIL] dashboard not answering at %s\n' "$url"
    fi
fi

# Root storage type. microSD I/O stalls are the usual cause of slow unit
# starts and log-write latency; flag it and point at the SSD fix.
echo
echo "=== Host root storage ==="
root_storage() {
    local dev base rot
    dev=$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null)
    if [[ -z "$dev" || "$dev" != /dev/* ]]; then
        echo "  could not determine root device"
        return
    fi
    base=${dev#/dev/}
    case "$base" in
        # Partitioned mmcblk/nvme: strip the pN suffix, keep the device index
        # (mmcblk0p2 -> mmcblk0, nvme0n1p2 -> nvme0n1). A bare mmcblk0/nvme0n1
        # (root on the whole device) matches neither arm and is left intact.
        mmcblk*p[0-9]* | nvme*n[0-9]*p[0-9]*) base=${base%p[0-9]*} ;;
        # Traditional disks only — strip trailing partition digits. Scoped so
        # it can't over-strip a bare nvme/mmc device number.
        sd*[0-9] | hd*[0-9] | vd*[0-9] | xvd*[0-9]) base=${base%%[0-9]*} ;;
    esac
    rot=$(cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo "?")
    case "$base" in
        mmcblk*)
            echo "  [WARN] root on SD card ($base) — microSD I/O stalls cause slow"
            echo "         unit starts and log writes; a USB3/NVMe SSD removes them"
            ;;
        nvme*)
            echo "  [OK]   root on $base (NVMe SSD)" ;;
        *)
            if [[ "$rot" == "0" ]]; then
                echo "  [OK]   root on $base (SSD/flash)"
            elif [[ "$rot" == "1" ]]; then
                echo "  [OK]   root on $base (spinning disk)"
            else
                echo "  [OK]   root on $base"
            fi
            ;;
    esac
}
root_storage

echo
echo "For deeper diagnostics:"
echo "  svx health"
echo "  svx bug-report"
echo "  ~/.local/bin/svx-recovery doctor"
