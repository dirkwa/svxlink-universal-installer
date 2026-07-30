#!/usr/bin/env bash
# Pre-install checks for svxlink-universal-installer: RAM, disk, /tmp
# tmpfs heads-up, dashboard port + EchoLink UDP ports, cgroups v2 (incl.
# the Pi kernel-cmdline patch), podman version, subuid/subgid, linger,
# rootless-storage backing filesystem, distro gate.
#
# Exits non-zero on the first hard failure unless FORCE=1 is set.
# Exit code 2 has a dedicated meaning for the caller (install.sh): a Pi
# kernel cmdline patch was applied and the host must reboot before
# re-running the installer.
#
# Trimmed against the signalk reference on purpose:
#   - no 80/443/privileged-port machinery (the server is Network=host
#     with UDP-only EchoLink ports; the dashboard defaults to :8080),
#   - no legacy-v1/orphan-container sweeps (there is no v1),
#   - no user-slice delegation check (this stack sets no Memory*/CPU
#     limits on any unit — see install.sh's drop-in omission comment),
#   - no aardvark/nft presence probes (install.sh re-ensures both).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"

# Login shells set USER, but `podman exec`, cron, and some systemd
# contexts don't — with `set -u` the first ${USER} dereference then
# kills the whole preflight ("USER: unbound variable").
USER="${USER:-$(id -un)}"

detect_os

# svxlink idles around 30 MB RSS and the optional dashboard is a stock
# Apache/PHP; the C++-heavy part (compiling svxlink) happens in the
# image CI, never on this host. 512 MB (Pi Zero 2 W class) is
# realistically enough — so RAM is a warning floor, not a block.
REQUIRED_RAM_MB=${REQUIRED_RAM_MB:-512}
# Server image ~300 MB + the locally built dashboard image's layers +
# logs + the capped journal.
REQUIRED_DISK_GB=${REQUIRED_DISK_GB:-3}
# Informational-/tmp-heads-up bounds (see check_tmp_on_tmpfs).
TMPFS_WARN_MAX_RAM_MB=${TMPFS_WARN_MAX_RAM_MB:-8192}
TMPFS_RECOMMEND_PCT=${TMPFS_RECOMMEND_PCT:-20}
# The only TCP port this stack ever binds: the (optional) dashboard.
# install.sh exports the operator's choice; default matches the quadlet
# template's __DASH_PORT__ default.
SVX_DASH_PORT=${SVX_DASH_PORT:-8080}
# EchoLink's inbound UDP pair. svxlink binds them under Network=host, so
# another EchoLink/svxlink instance on the box is a real (if
# warn-level) conflict — rootless ss can't attribute an owner, and the
# node still starts without EchoLink, hence warn not fail.
ECHOLINK_UDP_PORTS=(5198 5199)
# 5.3: Quadlet gained the `[Quadlet] DefaultDependencies=false` key the
# server quadlet relies on to suppress the user-session network-wait
# shim (silently ignored below 5.3 — the unit then blocks ~90s on every
# boot). Trixie ships 5.4.x, so this excludes no supported host.
PODMAN_MIN_VERSION="5.3"

fail() {
    err "$@"
    if [[ "${FORCE:-0}" != "1" ]]; then
        die "Aborting. Set FORCE=1 to override (not recommended)."
    fi
    warn "FORCE=1, continuing despite failure"
}

check_ram() {
    local mb
    mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    if (( mb < REQUIRED_RAM_MB )); then
        warn "RAM ${mb}MB < recommended ${REQUIRED_RAM_MB}MB — svxlink will run, but keep the dashboard off and the journal capped"
    else
        ok "RAM ${mb}MB"
    fi
}

check_disk() {
    local target="${HOME}"
    local gb
    gb=$(df -BG --output=avail "$target" | tail -1 | tr -dc 0-9)
    if (( gb < REQUIRED_DISK_GB )); then
        fail "Free disk on ${target}: ${gb}GB < required ${REQUIRED_DISK_GB}GB"
    else
        ok "Free disk ${gb}GB on ${target}"
    fi
}

# Filesystem type backing /tmp, or empty if undeterminable. Own helper
# so the branching can be unit-tested by stubbing this and _total_ram_mb.
_tmp_fstype() {
    if command -v findmnt >/dev/null 2>&1; then
        # -T resolves to whatever mount /tmp actually falls under.
        findmnt -nro FSTYPE -T /tmp 2>/dev/null || true
    else
        # Fallback without util-linux findmnt: an exact-path match only
        # catches /tmp when it IS a separate mount — exactly the tmpfs
        # case we care about.
        awk '$2 == "/tmp" {print $3; exit}' /proc/mounts 2>/dev/null || true
    fi
}

_total_ram_mb() {
    awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo
}

# Debian 13 / trixie (and Pi OS trixie+) mount /tmp on tmpfs by default.
# tmpfs is RAM-backed, so on a small-RAM node a process that fills /tmp
# uses memory the container stack wants. Informational heads-up only
# (info, not warn, non-blocking) — shown only on machines small enough
# for it to matter. The suggested tweak SHRINKS the tmpfs cap rather
# than moving /tmp to disk: staying in RAM avoids SD-card write wear.
check_tmp_on_tmpfs() {
    local fstype
    fstype=$(_tmp_fstype)
    if [[ "$fstype" != "tmpfs" ]]; then
        ok "/tmp is on disk (${fstype:-unknown} fs)"
        return 0
    fi
    local ram_mb cap_mb
    ram_mb=$(_total_ram_mb)
    cap_mb=$(df -BM --output=size /tmp 2>/dev/null | tail -1 | tr -dc 0-9)
    if (( ram_mb > TMPFS_WARN_MAX_RAM_MB )); then
        ok "/tmp is on tmpfs (cap ${cap_mb:-?}MB; ${ram_mb}MB RAM — headroom OK)"
        return 0
    fi
    local opts="mode=1777,strictatime,nosuid,nodev,size=${TMPFS_RECOMMEND_PCT}%,nr_inodes=1m"
    info "/tmp is on tmpfs (RAM-backed): cap ${cap_mb:-?}MB on ${ram_mb}MB RAM."
    info "  This is the Debian 13 / trixie default and fine as-is — just a"
    info "  heads-up: if something fills /tmp it uses RAM the containers"
    info "  could otherwise have. To cap it at ${TMPFS_RECOMMEND_PCT}% of RAM:"
    info "    sudo mkdir -p /etc/systemd/system/tmp.mount.d"
    info "    printf '[Mount]\\nOptions=${opts}\\n' \\"
    info "      | sudo tee /etc/systemd/system/tmp.mount.d/size.conf"
    info "    sudo systemctl daemon-reload && sudo reboot"
}

# `bootstrappedAt` in ~/.svxlink/last-good.json is written by
# install.sh's verify step on every successful pass. Its presence means
# this isn't a fresh install — a dashboard port held by the managed
# svxlink-dashboard container is expected state, not a collision. Used
# only to word the failure hint; per-port attribution is decided by
# managed_container_running (the marker lands only at the very last
# step, so gating attribution on it broke re-runs of installs that died
# in a late optional step).
is_verify_mode() {
    local marker="${HOME}/.svxlink/last-good.json"
    [[ -f "$marker" ]] && grep -q '"bootstrappedAt"' "$marker" 2>/dev/null
}

managed_container_running() {
    local name=$1
    command -v podman >/dev/null 2>&1 || return 1
    podman ps --filter "name=^${name}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "$name"
}

check_ports() {
    local verify=0
    is_verify_mode && verify=1
    # TCP: only the dashboard port. A bound port is "expected" when the
    # managed svxlink-dashboard container is actually running; anything
    # else holding it is a real conflict.
    if ss -ltn "( sport = :$SVX_DASH_PORT )" 2>/dev/null | tail -n +2 | grep -q .; then
        if managed_container_running svxlink-dashboard; then
            ok "Port ${SVX_DASH_PORT} held by the managed svxlink-dashboard (expected — existing install)"
        elif (( verify )); then
            fail "Port ${SVX_DASH_PORT} in use but not by svxlink-dashboard — a stray process is holding it. Check 'podman ps' / 'ss -ltnp', or pick another port via SVX_DASH_PORT."
        else
            fail "Port ${SVX_DASH_PORT} already in use — stop the conflicting service or set SVX_DASH_PORT to a free port"
        fi
    else
        ok "Dashboard port ${SVX_DASH_PORT} is free"
    fi
    # UDP: EchoLink's 5198/5199. svxlink itself holds them once running
    # (Network=host), so attribute to the managed server first.
    local p busy=()
    for p in "${ECHOLINK_UDP_PORTS[@]}"; do
        if ss -lun "( sport = :$p )" 2>/dev/null | tail -n +2 | grep -q .; then
            busy+=("$p")
        fi
    done
    if (( ${#busy[@]} == 0 )); then
        ok "EchoLink UDP ports ${ECHOLINK_UDP_PORTS[*]} are free"
    elif managed_container_running svxlink-server; then
        ok "UDP ${busy[*]} held while svxlink-server runs (expected — existing install)"
    else
        warn "UDP port(s) ${busy[*]} already bound — another EchoLink/svxlink"
        warn "instance? The node will start, but EchoLink cannot bind its"
        warn "inbound ports until the other process is stopped."
    fi
}

check_cgroups_v2() {
    if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        fail "cgroups v2 not detected (no /sys/fs/cgroup/cgroup.controllers)"
        return
    fi
    local ctl
    ctl=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo "")
    local missing=""
    grep -qw memory <<<"$ctl" || missing+=" memory"
    grep -qw pids <<<"$ctl" || missing+=" pids"
    if [[ -n "$missing" ]]; then
        # On a Pi, surface the recipe and the interactive autofix BEFORE
        # the fail() — fail() exits, so anything after it is dead code on
        # a default-config run. If offer_pi_cmdline_fix returns 0 the
        # patch was applied and the operator just needs to reboot; exit 2
        # so the calling install.sh stops cleanly with the reboot message
        # instead of marching into podman/linger steps.
        err "cgroups v2 missing controller(s):$missing"
        if is_pi && [[ -r /proc/cmdline ]] && grep -qw 'cgroup_disable=memory' /proc/cmdline; then
            # Pi OS ships with cgroup_disable=memory injected by the GPU
            # firmware on some images; systemd (and podman's cgroup
            # handling) want the controller present.
            warn "Detected cgroup_disable=memory in /proc/cmdline."
            warn "Enable the memory controller (one-time, requires sudo + reboot):"
            warn "  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak.\$(date +%Y%m%d)"
            warn "  sudo sed -i 's/\\bcgroup_disable=memory\\b//; s/\$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt"
            warn "  # /boot/firmware/cmdline.txt must remain a single line — verify: wc -l /boot/firmware/cmdline.txt"
            warn "  sudo reboot"
            if offer_pi_cmdline_fix strip-disable; then
                exit 2
            fi
        elif is_pi; then
            warn "On Raspberry Pi, enable the memory controller (one-time, requires sudo + reboot):"
            warn "  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak.\$(date +%Y%m%d)"
            warn "  sudo sed -i 's/\$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt"
            warn "  # /boot/firmware/cmdline.txt must remain a single line — verify: wc -l /boot/firmware/cmdline.txt"
            warn "  sudo reboot"
            if offer_pi_cmdline_fix enable-only; then
                exit 2
            fi
        fi
        # Already printed via err above; honor FORCE=1 as fail() would.
        if [[ "${FORCE:-0}" != "1" ]]; then
            die "Aborting. Set FORCE=1 to override (not recommended)."
        fi
        warn "FORCE=1, continuing despite failure"
    else
        ok "cgroups v2 with memory + pids"
    fi
}

# Offer to apply the cmdline.txt patch interactively. Mode is either
# "strip-disable" (also removes cgroup_disable=memory) or "enable-only"
# (just appends the enable flags). Skips silently when there's no TTY
# (curl|bash from cron, CI), when cmdline.txt isn't where we expect, or
# when the user declines. Never auto-reboots.
#
# Returns 0 only when the patch was applied successfully (caller then
# exits 2 so the operator sees "reboot, then re-run" instead of the
# generic preflight-fail message). Returns 1 in every other case so the
# caller falls through to the normal fail() path.
offer_pi_cmdline_fix() {
    local mode=$1
    local cmdline=/boot/firmware/cmdline.txt
    if [[ ! -f "$cmdline" ]] || [[ ! -r "$cmdline" ]]; then
        return 1
    fi
    if [[ ! -r /dev/tty ]] || [[ ! -w /dev/tty ]]; then
        # No controlling terminal — the printed instructions are the
        # only path.
        return 1
    fi
    local current proposed
    current=$(cat "$cmdline")
    case "$mode" in
        strip-disable)
            # \b is GNU-sed only; the [[:space:]] form is portable and
            # matches cgroup_disable=memory only as a whole token.
            proposed=$(sed -E 's/(^|[[:space:]])cgroup_disable=memory($|[[:space:]])/\1\2/g' <<<"$current")
            proposed="${proposed%$'\n'} cgroup_enable=memory cgroup_memory=1"
            ;;
        enable-only)
            proposed="${current%$'\n'} cgroup_enable=memory cgroup_memory=1"
            ;;
        *)
            return 1
            ;;
    esac
    # Collapse doubled spaces from the strip, then trim leading/trailing
    # whitespace (the strip can leave a leading space when the disable
    # flag was the first token).
    proposed=$(tr -s ' ' <<<"$proposed")
    proposed="${proposed#"${proposed%%[![:space:]]*}"}"
    proposed="${proposed%"${proposed##*[![:space:]]}"}"
    if [[ -z "$proposed" ]] || [[ $(wc -l <<<"$proposed") -ne 1 ]]; then
        warn "Refusing to offer auto-patch: proposed cmdline is not a single line."
        return 1
    fi
    printf '\n%sProposed change to %s:%s\n' "$C_BOLD" "$cmdline" "$C_RESET" >/dev/tty
    diff -u --label "current" --label "proposed" \
        <(printf '%s\n' "$current") <(printf '%s\n' "$proposed") >/dev/tty || true
    printf '\nApply this patch now (sudo, no reboot)? [y/N] ' >/dev/tty
    local reply=""
    read -r reply </dev/tty || return 1
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            info "Skipped cmdline.txt patch. Apply manually with the commands above when ready."
            return 1
            ;;
    esac
    local backup ts
    ts=$(date +%Y%m%d-%H%M%S)
    backup="${cmdline}.bak.${ts}"
    local sudo_cmd=()
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd=(sudo)
        else
            err "sudo not available — cannot edit $cmdline as $USER."
            return 1
        fi
    fi
    info "Backing up $cmdline → $backup"
    if ! "${sudo_cmd[@]}" cp -p "$cmdline" "$backup"; then
        err "Backup failed; not editing $cmdline."
        return 1
    fi
    if ! printf '%s\n' "$proposed" | "${sudo_cmd[@]}" tee "$cmdline" >/dev/null; then
        err "Write to $cmdline failed; restoring backup."
        "${sudo_cmd[@]}" cp -p "$backup" "$cmdline" || err "Restore from $backup also failed — fix manually before rebooting."
        return 1
    fi
    # cmdline.txt MUST be a single line; some bootloaders silently
    # refuse to apply settings past the first newline. An empty file is
    # also a failure mode — restore on any non-1 line count.
    local lines
    lines=$(wc -l <"$cmdline")
    if [[ "$lines" -ne 1 ]]; then
        err "$cmdline ended up with $lines lines; restoring backup."
        "${sudo_cmd[@]}" cp -p "$backup" "$cmdline" || err "Restore from $backup also failed — fix manually before rebooting."
        return 1
    fi
    ok "Patched $cmdline (backup at $backup)."
    warn "Reboot required for the kernel to expose the memory controller:"
    warn "  sudo reboot"
    warn "Re-run the installer after the reboot."
    return 0
}

check_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        warn "Podman not installed — installer will install it"
        return
    fi
    local v
    v=$(podman --version 2>/dev/null | awk '{print $3}')
    local req_major=${PODMAN_MIN_VERSION%%.*}
    local req_minor=${PODMAN_MIN_VERSION#*.}
    local cur_major cur_minor
    cur_major=$(cut -d. -f1 <<<"$v")
    cur_minor=$(cut -d. -f2 <<<"$v")
    if (( cur_major < req_major )) || { (( cur_major == req_major )) && (( cur_minor < req_minor )); }; then
        fail "Podman $v < required $PODMAN_MIN_VERSION (Quadlet network-dependency control)"
    else
        ok "Podman $v"
    fi
}

check_subid() {
    if [[ ! -f /etc/subuid ]] || ! grep -q "^${USER}:" /etc/subuid; then
        warn "User $USER lacks subuid mapping — installer will run: sudo usermod --add-subuids 100000-165535"
    fi
    if [[ ! -f /etc/subgid ]] || ! grep -q "^${USER}:" /etc/subgid; then
        warn "User $USER lacks subgid mapping — installer will run: sudo usermod --add-subgids 100000-165535"
    fi
    ok "subuid/subgid will be ensured by installer"
}

check_linger() {
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        ok "linger enabled for $USER"
    else
        warn "linger not yet enabled — installer will run: loginctl enable-linger $USER"
    fi
}

# Path rootless podman uses for its image+container storage (graphroot),
# walked up to the nearest existing parent so `stat -f` always has
# something to probe on a fresh host.
podman_storage_root() {
    local root="${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
    local probe="$root"
    while [[ -n "$probe" && ! -e "$probe" ]]; do
        probe="${probe%/*}"
    done
    printf '%s\n' "${probe:-/}"
}

podman_storage_fstype() {
    stat -f -c '%T' "$(podman_storage_root)" 2>/dev/null || true
}

check_storage_fs() {
    local fs
    fs=$(podman_storage_fstype)
    case "$fs" in
        zfs)
            # The kernel overlay driver doesn't work on ZFS, so podman
            # silently falls back to the vfs driver — every layer is a
            # full copy, pulls crawl and the store balloons. This stack
            # never uses UserNS=keep-id (root-in-userns by contract), so
            # the reference's chown-by-maps hazard doesn't apply — but
            # fuse-overlayfs is still the right driver here. Manual
            # recipe (this installer doesn't autofix storage.conf):
            warn "Rootless storage is on ZFS — configure fuse-overlayfs BEFORE the first pull:"
            warn "  sudo apt-get install -y fuse-overlayfs"
            warn "  mkdir -p ~/.config/containers && printf '[storage]\\ndriver = \"overlay\"\\n\\n[storage.options.overlay]\\nmount_program = \"/usr/bin/fuse-overlayfs\"\\n' > ~/.config/containers/storage.conf"
            warn "  podman system migrate"
            ;;
        "")
            warn "Could not determine rootless storage filesystem (probed $(podman_storage_root))"
            ;;
        *)
            ok "Rootless storage on $fs (no special handling needed)"
            ;;
    esac
}

check_distro_blocked() {
    # Debian 12 (bookworm) ships podman 4.3.1; Quadlet support arrived
    # in 4.4 and Debian removed podman from bookworm-backports — there
    # is no in-Debian-repo path to a usable version. Bail with a clear
    # upgrade message rather than failing later, mid-apt, with a
    # confusing dependency error.
    if [[ "$DISTRO_ID" = "debian" && "$DISTRO_CODENAME" = "bookworm" ]]; then
        err "Debian 12 (bookworm) is not supported by this installer."
        echo >&2
        err "Bookworm ships Podman 4.3.1 which lacks Quadlet (added in 4.4),"
        err "and bookworm-backports does not carry a newer version."
        echo >&2
        err "Upgrade to Debian 13 (trixie):"
        err "  1. As root, edit /etc/apt/sources.list and replace 'bookworm'"
        err "     with 'trixie' on every active line (also under"
        err "     /etc/apt/sources.list.d/ if you have files there)."
        err "  2. apt-get update"
        err "  3. apt-get full-upgrade"
        err "  4. reboot"
        err "  5. Re-run this installer."
        exit 1
    fi
}

main() {
    section "Pre-flight on ${DISTRO_PRETTY} (${ARCH_NORM})"
    check_distro_blocked
    if ! is_supported_distro; then
        warn "Untested on ${DISTRO_PRETTY}; continuing"
    fi
    check_ram
    check_disk
    check_tmp_on_tmpfs
    check_ports
    check_cgroups_v2
    check_podman
    check_subid
    check_linger
    check_storage_fs
}

# Only run the checks when executed directly. When sourced (e.g. by the
# test harness to exercise individual helpers), define the functions but
# don't run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
