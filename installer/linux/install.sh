#!/usr/bin/env bash
# SvxLink Universal Installer — Linux bootstrap.
#
# One-shot installer. After it finishes, systemd-user owns the runtime
# (Quadlet-generated svxlink-server.service) and the `svx` CLI owns
# updates, rendering and health. There are no engine containers and no
# auto-update timer: this script never runs continuously.
#
# Steps (idempotent; safe to re-run after partial failures):
#   1. Detect distro + arch, refuse root, validate sudo
#   2. Pre-flight (RAM/disk, dashboard port + EchoLink UDP 5198/5199,
#      cgroups v2 incl. Pi cmdline patch [exit 2 = reboot-and-re-run],
#      podman version, subuid/linger, storage fs, distro gate)
#   3. Install packages (podman passt uidmap slirp4netns aardvark-dns
#      nftables jq alsa-utils; + gpiod on a Pi); re-ensure the
#      Recommends-gapped helpers on hosts that arrived with podman
#   4. podman >= 5.3 gate, re-checked AFTER apt
#   5. subuid/subgid ranges + podman system migrate
#   6. Group memberships (audio, dialout; gpio where the group exists)
#   7. systemd-user linger
#   8. Journald drop-in (persistent + capped). Deliberately NOTHING
#      else: no podman.socket, no TasksMax, no delegate.conf, no
#      nofile.conf — each omission is justified at the step.
#   9. Resolve the server image from SVX_CHANNEL (or the live quadlet's
#      Image= on re-runs), prune dangling layers, bounded pull
#  10. Seed ~/.svxlink/etc from the image's pristine /etc/svxlink and
#      apply callsign/EchoLink answers (seed-config.sh; only-if-absent,
#      never clobbers on re-runs)
#  11. Install host CLI tools (svx, svx-recovery, /usr/local/bin
#      symlink, PATH snippet) and stage ~/.svxlink/payload/ — BEFORE
#      any container start, so the operator always has the tools when a
#      later step fails
#  12. Hardware detection -> ~/.svxlink/hardware.json (+ the optional
#      interactive audio/PTT wizard, offered only on a TTY)
#  13. Render the server quadlet (payload renderer), daemon-reload,
#      start — drift-gated restart on re-runs
#  14. Dashboard, only when SVX_DASHBOARD=1 (delegates to the freshly
#      installed `svx dashboard install`)
#  15. Verify (unit active, in-container pgrep, log-file growth after a
#      start) + write ~/.svxlink/last-good.json; re-runs add a
#      checkpoint sweep (VERIFY_MODE)
#  16. Summary
#
# Env knobs (all optional):
#   SVX_CHANNEL            latest|master|<version> — image tag for the
#                          first pull AND the rendered Image=
#   SVX_DASHBOARD=1        install the CN8VX web dashboard (default: no)
#   SVX_DASH_PORT/_BIND    dashboard publish port (8080) / bind (0.0.0.0)
#   SVX_CALLSIGN, SVX_LOGIC, SVX_ECHOLINK_CALLSIGN,
#   SVX_ECHOLINK_PASSWORD, SVX_SYSOP_NAME, SVX_TZ
#                          unattended config-seed answers (seed-config.sh)
#   SVX_NO_INSTALL_LOG=1   don't tee output to ~/.svxlink/install.log
#   SVX_INSTALLER_BASE     override the GitHub Pages base URL (local e2e)

INSTALLER_VERSION="${INSTALLER_VERSION:-0.0.0-scaffold}"
INSTALLER_BASE_URL="${SVX_INSTALLER_BASE:-https://dirkwa.github.io/svxlink-universal-installer}"

set -euo pipefail

# Login shells set USER, but `podman exec`, cron, and some systemd contexts
# don't — with `set -u` the first $USER dereference then aborts the run.
# id -un answers from the kernel. Exported so preflight.sh (subprocess)
# inherits it; preflight keeps its own guard for standalone invocation.
USER="${USER:-$(id -un)}"
export USER

# Resolve own location. When invoked as `curl ... | bash`, BASH_SOURCE[0]
# is empty and we're running from stdin — none of the adjacent lib/
# scripts, quadlet templates or dashboard seeds are on disk. In that case
# fetch them into a tempdir from INSTALLER_BASE_URL and re-run ourselves.
if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]:-/dev/null}" ]]; then
    TMP=$(mktemp -d -t svxlink-installer.XXXXXX)
    trap 'rm -rf "$TMP"' EXIT
    echo "[i] Fetching installer tree from ${INSTALLER_BASE_URL}"
    # This list is the single source of truth for what the curl|bash
    # bootstrap fetches. scripts/test/check-installer-manifest.sh parses
    # it out between the marker lines below and asserts every path exists
    # in the repo (and, with --remote, on Pages) — the guard against
    # "added a file, forgot the manifest". The svx CLI's self-update list
    # is a marked subset of this one; the same test keeps them in sync.
    # BEGIN FETCH MANIFEST
    FETCH_MANIFEST=(
        installer/linux/install.sh
        installer/linux/preflight.sh
        installer/linux/seed-config.sh
        installer/linux/detect-hardware.sh
        installer/linux/render-server-quadlet.sh
        installer/linux/install-svx-command.sh
        installer/linux/install-recovery-script.sh
        installer/linux/svx.tmpl
        installer/linux/svx-recovery.tmpl
        installer/linux/lib/colors.sh
        installer/linux/lib/distro.sh
        installer/linux/lib/http.sh
        installer/linux/lib/ghcr.sh
        installer/linux/lib/hardware-merge.sh
        installer/linux/lib/udev-rule.sh
        quadlets/svxlink-server.container.template
        quadlets/svxlink-dashboard.container.template
        dashboard/Containerfile
        dashboard/config.php.tmpl
        dashboard/dash_config.php.seed
        dashboard/talkgroups.json.seed
    )
    # END FETCH MANIFEST
    for f in "${FETCH_MANIFEST[@]}"; do
        mkdir -p "$TMP/$(dirname "$f")"
        if ! curl -fsSL "${INSTALLER_BASE_URL}/${f}" -o "$TMP/$f"; then
            echo "[ERR] Failed to fetch ${INSTALLER_BASE_URL}/${f}" >&2
            exit 1
        fi
    done
    chmod +x "$TMP/installer/linux/"*.sh
    chmod +x "$TMP/installer/linux/lib/"*.sh 2>/dev/null || true
    # Run the local copy as a child, NOT via `exec`. The original
    # `curl … | bash` invocation is still streaming bytes through this
    # bash's stdin; using `exec` here replaced the process before bash
    # had consumed the tail of install.sh, so curl hit SIGPIPE writing
    # to a pipe with no reader and exited 23 with a confusing
    # "Failure writing output to destination" line printed AFTER the
    # successful install summary. Running as a subprocess keeps this
    # bash alive; we then drain curl's leftover bytes to /dev/null so
    # curl sees a clean EOF instead of a broken pipe.
    rc=0
    env \
        INSTALLER_VERSION="$INSTALLER_VERSION" \
        SVX_INSTALLER_BASE="$INSTALLER_BASE_URL" \
        SVX_CHANNEL="${SVX_CHANNEL:-}" \
        SVX_DASHBOARD="${SVX_DASHBOARD:-}" \
        SVX_DASH_PORT="${SVX_DASH_PORT:-}" \
        SVX_DASH_BIND="${SVX_DASH_BIND:-}" \
        SVX_NO_INSTALL_LOG="${SVX_NO_INSTALL_LOG:-}" \
        SVX_CALLSIGN="${SVX_CALLSIGN:-}" \
        SVX_LOGIC="${SVX_LOGIC:-}" \
        SVX_ECHOLINK_CALLSIGN="${SVX_ECHOLINK_CALLSIGN:-}" \
        SVX_SYSOP_NAME="${SVX_SYSOP_NAME:-}" \
        SVX_TZ="${SVX_TZ:-}" \
        bash "$TMP/installer/linux/install.sh" "$@" || rc=$?
    # SVX_ECHOLINK_PASSWORD is intentionally NOT on the `env` argv line
    # above (that would expose it in `ps` of the env process). It reaches
    # the child by inheritance instead: `env VAR=val bash` adds to the
    # inherited environment rather than replacing it, so an exported
    # password passes straight through, off every command line.
    cat >/dev/null 2>&1 || true
    exit "$rc"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"
# shellcheck disable=SC1091
. "$HERE/lib/http.sh"
# ghcr.sh is only CALLED from the svx CLI (`svx channel` tag validation),
# but sourcing it here means a syntax error in it surfaces at install
# time instead of at the operator's first `svx channel` months later.
# shellcheck disable=SC1091
. "$HERE/lib/ghcr.sh"
# shellcheck disable=SC1091
. "$HERE/lib/hardware-merge.sh"

# Refuse root BEFORE the install-log tee below: run as root, the tee
# would first create /root/.svxlink/install.log — a root-owned leftover
# that `svx bug-report` (which runs as the regular user) can never
# bundle. The full rationale for refusing root lives at the
# privilege-escalation comment further down.
if (( EUID == 0 )); then
    err "Do not run the installer as root (su / root login / sudo bash)."
    echo >&2
    err "The SvxLink stack is rootless and tied to a regular user's"
    err "session: Quadlets, systemd --user units, linger, and ~/.svxlink"
    err "all belong to the user who runs this script. As root they would"
    err "land in root's home and session instead."
    echo >&2
    err "Run it as the user who should own the svxlink node. If that"
    err "user can't sudo yet, bootstrap once as root, then RECONNECT:"
    err "  1. apt-get update && apt-get install -y sudo"
    err "  2. /usr/sbin/usermod -aG sudo <youruser>"
    err "     (full path — a plain 'su' root shell lacks /usr/sbin on PATH)"
    err "  3. Log in as <youruser> (fresh SSH session, not su)."
    err "  4. Re-run the installer one-liner — it sudo's where needed."
    exit 1
fi

# Persist this run's console output to ~/.svxlink/install.log so
# `svx bug-report` can bundle it. The documented invocation is
# `curl … | bash` (output goes only to the terminal), so without this a
# failed install left no on-disk trace. We're past the curl|bash
# self-refetch branch above (which already exited), so this tees the
# real on-disk run, not the stdin bootstrap. Truncate (not append) at
# the start of each run so a re-install doesn't accumulate stale
# failures — the file is one install's worth of output.
# SVX_NO_INSTALL_LOG=1 opts out (e.g. read-only-home CI). No secrets
# land here: the EchoLink password is read with `read -rs` (never
# echoed) and applied via awk ENVIRON, never printed.
INSTALL_LOG="${HOME}/.svxlink/install.log"
case "${SVX_NO_INSTALL_LOG:-}" in
    1 | true | TRUE | yes | YES) INSTALL_LOG="" ;;
esac
if [[ -n "$INSTALL_LOG" ]] && mkdir -p "${HOME}/.svxlink" 2>/dev/null \
    && : >"$INSTALL_LOG" 2>/dev/null; then
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    info "Logging this run to $INSTALL_LOG"
fi

# --- Names and paths -------------------------------------------------------
# The image name is contract: docs/image-contract.md in svxlink-images is
# the single source of truth; check-image-contract.sh --remote greps this
# repo against that repo's raw files. Env override is for CI/mirrors only.
SVX_IMAGE_REPO="${SVX_IMAGE_REPO:-ghcr.io/dirkwa/svxlink-server}"

SVX_HOME="${HOME}/.svxlink"
QUADLET_DIR="${HOME}/.config/containers/systemd"
SERVER_QUADLET_FILE="$QUADLET_DIR/svxlink-server.container"
DASH_QUADLET_FILE="$QUADLET_DIR/svxlink-dashboard.container"
SNAP_DIR="$SVX_HOME/snapshots"
PAYLOAD_DIR="$SVX_HOME/payload"
SVX_LOG_FILE="$SVX_HOME/log/svxlink"
LAST_GOOD="$SVX_HOME/last-good.json"
DASH_PORT="${SVX_DASH_PORT:-8080}"
DASH_BIND="${SVX_DASH_BIND:-0.0.0.0}"
# Exported so the child `bash preflight.sh` checks the actual port.
export SVX_DASH_PORT="$DASH_PORT"

# Privilege escalation. The installer needs root for apt + usermod +
# linger + the journald drop-in + the /usr/local/bin symlink — but it
# must RUN as the regular user that will own the stack (Quadlets,
# `systemctl --user`, rootless podman storage, ~/.svxlink). Root runs
# were already refused above; here we only classify sudo availability.
# We don't try `su -c`: the curl-piped one-liner has no controlling tty
# for the password prompt and the failure mode is confusing.
if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO="MISSING"
fi

# Install OS packages portably. Debian/Raspberry Pi OS (the targets) use
# apt; dnf is kept for untested-but-plausible Fedora hosts; rpm-ostree
# images can't layer packages at runtime, so we refuse cleanly there.
# Args are Debian package names; the few that differ on Fedora are
# translated. Returns non-zero (without aborting the caller) when it
# genuinely couldn't install, so callers can decide whether the package
# was optional.
pkg_install() {
    local debs=("$@") pm="" pkgs=() p
    if command -v apt-get >/dev/null 2>&1; then
        pm="apt"
    elif command -v dnf >/dev/null 2>&1; then
        pm="dnf"
    elif command -v rpm-ostree >/dev/null 2>&1; then
        warn "Cannot install (${debs[*]}) on an rpm-ostree system at runtime."
        return 1
    else
        warn "No supported package manager (apt-get/dnf) found; cannot install (${debs[*]})."
        return 1
    fi
    if [[ "$pm" == "apt" ]]; then
        $SUDO apt-get update
        $SUDO apt-get install -y "${debs[@]}"
        return $?
    fi
    for p in "${debs[@]}"; do
        case "$p" in
            uidmap) pkgs+=("shadow-utils") ;;
            *)      pkgs+=("$p") ;;
        esac
    done
    $SUDO dnf install -y "${pkgs[@]}"
}

# 1. Detect host
detect_os
section "SvxLink Universal Installer v${INSTALLER_VERSION#v}"
info "Host: ${DISTRO_PRETTY} (${ARCH_NORM})"
if [[ "$SUDO" = "MISSING" ]]; then
    err "Running as non-root user '$USER' and sudo is not installed."
    echo >&2
    err "Bootstrap sudo as root, then RECONNECT your SSH session:"
    err "  1. Become root (e.g.  su -)"
    err "  2. apt-get update && apt-get install -y sudo"
    err "  3. /usr/sbin/usermod -aG sudo $USER"
    err "  4. exit  # leave the root shell"
    err "  5. CLOSE the SSH session entirely and reconnect."
    err "     (su / newgrp / exec bash do NOT pick up the new group —"
    err "     Linux assigns groups when the session starts, not on"
    err "     subshell entry.)"
    err "  6. After reconnect, verify with:  groups | grep -qw sudo && echo OK"
    err "  7. Re-run the installer one-liner."
    exit 1
fi
# Probe whether sudo will actually let this user escalate, BEFORE we
# start running steps that depend on it. `sudo -nv` returns 0 when the
# timestamp is already cached, 1 when sudo would prompt OR when the user
# is not authorized; we distinguish by looking for the "not in sudoers"
# patterns sudo emits to stderr (English + the localized forms we've
# seen in the wild). The typical cause is `usermod -aG sudo $USER`
# without a full SSH reconnect (the running session still has the stale
# group set; only a fresh login refreshes it).
sudo_probe=$(sudo -nv 2>&1 || true)
if grep -qiE 'not (in the sudoers|allowed)|may not run sudo|nicht in der sudoers' <<<"$sudo_probe"; then
    err "'$USER' is not authorized to use sudo."
    echo >&2
    err "If you just added the user to the sudo group, CLOSE this SSH"
    err "session entirely and reconnect — su / exec bash / newgrp do"
    err "NOT refresh the kernel's group credentials for the running"
    err "session. Only a fresh login does."
    echo >&2
    err "After reconnect, verify with:  groups | grep -qw sudo && echo OK"
    err "Then re-run the installer one-liner."
    echo >&2
    err "If '$USER' really isn't in the sudo group at all, add it as"
    err "root first:  /usr/sbin/usermod -aG sudo $USER"
    exit 1
fi
# The -nv probe above can't catch every non-sudoer: sudo authenticates
# BEFORE the sudoers lookup, so with -n a non-sudoer often just gets "a
# password is required" (localized) and sails past the pattern grep. So
# validate for real, once, with a NON-INTERACTIVE real command
# (`sudo -n true`) — that's what the installer actually does, and it's
# exactly what NOPASSWD covers. Deliberately NOT `sudo -n -v`: `-v` only
# refreshes the credential timestamp and on many sudoers configs still
# demands a password even when NOPASSWD applies to commands — which
# fails in a no-TTY context even though `sudo -n true` succeeds. Only if
# it fails do we fall back to an interactive `sudo -v`, and only when a
# TTY exists.
if ! sudo -n true 2>/dev/null; then
    if [[ -t 0 || -r /dev/tty ]]; then
        sudo_ok=0
        sudo -v && sudo_ok=1
    else
        sudo_ok=0
    fi
    if [[ "$sudo_ok" != "1" ]]; then
        err "sudo validation failed for '$USER' — cannot continue."
        echo >&2
        err "Either the password was wrong, or '$USER' is not authorized"
        err "to use sudo (and there is no TTY to prompt for a password)."
        err "If you just added the user to the sudo group, CLOSE this SSH"
        err "session entirely and reconnect, then verify with:"
        err "  groups | grep -qw sudo && echo OK"
        echo >&2
        err "For an unattended/no-TTY run, grant passwordless sudo as root:"
        err "  echo '$USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-$USER-nopasswd"
        exit 1
    fi
fi

# Channel/image resolution. The quadlet's Image= tag is OperatorIntent
# (the channel): a re-run must NOT silently reset an operator's
# `svx channel master` (or a rollback's digest pin) back to :latest, so
# SVX_CHANNEL only overrides when explicitly non-empty — the curl|bash
# re-exec forwards it set-but-empty on every run, so a presence test
# would misfire. With no explicit channel and a live quadlet, the live
# Image= wins; on a truly fresh install the default is :latest.
channel_to_tag() {
    case "$1" in
        latest) echo "latest" ;;
        master) echo "master" ;;
        *)      echo "$1" ;;    # a version tag (26.05.1) — used verbatim
    esac
}
IMAGE=""
if [[ -n "${SVX_CHANNEL:-}" ]]; then
    : # explicit channel — resolution below prefers it over the live Image=
    IMAGE="${SVX_IMAGE_REPO}:$(channel_to_tag "$SVX_CHANNEL")"
elif [[ -f "$SERVER_QUADLET_FILE" ]]; then
    IMAGE=$(sed -n 's/^Image=//p' "$SERVER_QUADLET_FILE" 2>/dev/null | head -1 || true)
fi
[[ -n "$IMAGE" ]] || IMAGE="${SVX_IMAGE_REPO}:latest"
info "Server image: $IMAGE"

# Detect a previous successful install. The verify step writes
# `bootstrappedAt` into ~/.svxlink/last-good.json after every successful
# pass; presence of that key means at least one full bootstrap
# completed. The run sequence doesn't change — every step is idempotent
# — but a checkpoint sweep is added at the end (VERIFY_MODE) reporting
# what's healthy vs. still broken after the re-run.
VERIFY_MODE=0
if [[ -f "$LAST_GOOD" ]] && grep -q '"bootstrappedAt"' "$LAST_GOOD" 2>/dev/null; then
    VERIFY_MODE=1
    info "Existing install detected — running in verify mode."
fi

# 2. Pre-flight
section "Pre-flight"
# Preflight may apply a kernel-cmdline patch that requires a reboot (Pi
# memory controller). It signals that case with exit code 2 — its own
# messages already told the operator what to do; we just stop cleanly.
set +e
bash "$HERE/preflight.sh"
PREFLIGHT_RC=$?
set -e
if (( PREFLIGHT_RC == 2 )); then
    info "Preflight applied a kernel cmdline patch; reboot and re-run this installer."
    exit 0
elif (( PREFLIGHT_RC != 0 )); then
    exit "$PREFLIGHT_RC"
fi

# 3. Packages
section "Podman + host tools"
if ! command -v podman >/dev/null 2>&1; then
    # passt, aardvark-dns and nftables are explicit, not left to podman's
    # dependency pull: on Debian all three are only a Recommends (of
    # podman and netavark), and Armbian ships with
    # APT::Install-Recommends off — podman installs fine but the pasta
    # binary is missing and the pasta-networked dashboard container fails
    # to start, and without nftables netavark cannot exec nft. jq drives
    # hardware-merge + last-good.json; alsa-utils supplies aplay/arecord
    # for the audio wizard and bug reports; git is what `svx dashboard
    # install` clones the (license-bound, locally-built) dashboard with —
    # fresh Trixie ships without it.
    info "Installing podman + passt + uidmap + slirp4netns + aardvark-dns + nftables + jq + alsa-utils + git (requires sudo)"
    if ! pkg_install podman passt uidmap slirp4netns aardvark-dns nftables jq alsa-utils git; then
        err "Could not install podman. Install it manually and re-run."
        exit 1
    fi
fi
ok "$(podman --version)"

# Hosts that arrived WITH podman preinstalled (Armbian images, prior
# manual installs) skip the block above, so re-ensure the helpers
# separately. podman >= 5 defaults rootless networking to pasta; the
# svxlink-server quadlet is Network=host and doesn't care, but the
# dashboard container publishes its port through pasta and fails to
# start without the binary. Warn-not-fatal: a host configured for
# slirp4netns via containers.conf works without pasta.
if ! command -v pasta >/dev/null 2>&1; then
    info "Installing passt (pasta rootless networking backend, requires sudo)"
    pkg_install passt || true
    if ! command -v pasta >/dev/null 2>&1; then
        warn "pasta still not found — the dashboard container may fail to"
        warn "start. Install it manually (apt-get install passt) if it does."
    fi
fi

# Same Recommends gap for aardvark-dns. This stack defines no
# user-defined container networks itself, but netavark hands containers
# the bridge gateway as nameserver the moment the operator adds one —
# and then every lookup fails with "connection refused" if the binary is
# missing. Ask podman where it resolved the helper (covers custom
# helper_binaries_dir); the binary is not on PATH, so fall back to the
# packaged locations rather than command -v. Warn-not-fatal.
have_aardvark_dns() {
    local p
    p="$(podman info --format '{{.Host.NetworkBackendInfo.DNS.Path}}' 2>/dev/null || true)"
    if [[ -n "$p" && -x "$p" ]]; then
        return 0
    fi
    [[ -x /usr/lib/podman/aardvark-dns || -x /usr/libexec/podman/aardvark-dns ]] \
        || command -v aardvark-dns >/dev/null 2>&1
}
if ! have_aardvark_dns; then
    info "Installing aardvark-dns (DNS for user-defined container networks, requires sudo)"
    pkg_install aardvark-dns || true
    if ! have_aardvark_dns; then
        warn "aardvark-dns still not found — containers on user-defined"
        warn "networks cannot resolve DNS. Install it manually if needed."
    fi
fi

# And once more for nftables: netavark's firewall driver execs the nft
# binary when it wires a container network, but nftables is only a
# Recommends of netavark — on recommends-off hosts (Armbian) every
# bridge-networked container fails to start with "netavark: unable to
# execute nft: No such file or directory". nft lives in /usr/sbin, which
# user shells often drop from PATH, so probe the packaged locations too.
have_nft() {
    command -v nft >/dev/null 2>&1 || [[ -x /usr/sbin/nft || -x /sbin/nft ]]
}
if ! have_nft; then
    info "Installing nftables (netavark firewall backend, requires sudo)"
    pkg_install nftables || true
    if ! have_nft; then
        warn "nft still not found — containers on bridge networks cannot"
        warn "start. Install it manually (apt-get install nftables) if they fail."
    fi
fi

# jq drives hardware-merge, last-good.json and `svx bug-report`'s JSON
# handling — every consumer guards `command -v jq` and degrades without
# it (render-server-quadlet.sh has a grep/sed serial-only fallback), so
# best-effort only.
if ! command -v jq >/dev/null 2>&1; then
    info "Installing jq (optional; requires sudo)"
    pkg_install jq || warn "jq unavailable — optional JSON steps will degrade."
fi
# alsa-utils: aplay -l enumeration for the audio wizard + bug reports.
# Best-effort — the wizard also reads /proc/asound directly.
if ! command -v aplay >/dev/null 2>&1; then
    info "Installing alsa-utils (audio wizard + diagnostics; requires sudo)"
    pkg_install alsa-utils || warn "alsa-utils unavailable — audio wizard output will be sparse."
fi
# gpiod (gpiodetect/gpioinfo) only where GPIO PTT is plausible — a Pi.
# The container-side GPIO access needs no host tool; this is purely the
# wizard's chip/line picker.
if is_pi && ! command -v gpiodetect >/dev/null 2>&1; then
    info "Installing gpiod (GPIO PTT wizard tooling; requires sudo)"
    pkg_install gpiod || warn "gpiod unavailable — GPIO PTT setup will need manual chip/line numbers."
fi

# 4. Re-gate the podman version AFTER the install. Preflight runs before
# the apt step, so on a host that arrived without podman it never saw
# the version apt would lay down. Some distros ship a too-old podman in
# their own archive, and the `[Quadlet] DefaultDependencies=false` key
# the server quadlet relies on is silently ignored below 5.3, re-arming
# the network-wait shim that stalls startup ~90s on every boot. Fail
# loudly here rather than proceed to a setup that hangs with no obvious
# cause.
PODMAN_MIN_VERSION="5.3"
pv=$(podman --version 2>/dev/null | awk '{print $3}')
pv_major=${pv%%.*}
pv_minor=$(cut -d. -f2 <<<"$pv")
req_major=${PODMAN_MIN_VERSION%%.*}
req_minor=${PODMAN_MIN_VERSION#*.}
if (( pv_major < req_major )) || { (( pv_major == req_major )) && (( pv_minor < req_minor )); }; then
    err "Podman $pv is below the required $PODMAN_MIN_VERSION."
    err "This release's archive podman is too old for rootless Quadlet"
    err "network-dependency control; the stack will stall on startup."
    err "Install podman >= $PODMAN_MIN_VERSION (e.g. a newer OS release whose"
    err "archive ships it) and re-run this installer."
    exit 1
fi

# 5. Ensure subuid/subgid ranges exist for rootless podman. Debian/Pi OS
# auto-populate them for human users via adduser, so this is a no-op
# there — but minimally-provisioned images can lack a range, and then
# the very first `podman pull` fails with "no subuid ranges found".
# Idempotent: only added when missing.
if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null; then
    info "Adding subuid range for $USER (rootless podman; requires sudo)"
    $SUDO usermod --add-subuids 100000-165535 "$USER" || warn "could not add subuid range for $USER"
fi
if ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    info "Adding subgid range for $USER (rootless podman; requires sudo)"
    $SUDO usermod --add-subgids 100000-165535 "$USER" || warn "could not add subgid range for $USER"
fi
# Re-read the (possibly new) ranges so the first pull doesn't trip over
# a stale user-namespace mapping.
podman system migrate >/dev/null 2>&1 || true

# 6. Groups
section "Group memberships"
# Device access for the root-in-userns container rides on the INVOKING
# user's supplementary groups via GroupAdd=keep-groups (crun
# keep-original-groups) — never on a uid map. So the host user needs:
#   audio   — /dev/snd/* is root:audio 0660; also the group our CM108
#             udev rule assigns to the hidraw PTT node (which is
#             root:root 0600 out of the box — keep-groups alone can
#             never reach it, hence the rule).
#   dialout — serial PTT (/dev/ttyUSB* is root:dialout). Cheap,
#             harmless if unused.
#   gpio    — Pi GPIO PTT/COS (/dev/gpiochip* is root:gpio). Only added
#             when the group exists (plain Debian has none).
SVX_GROUPS=(audio dialout)
if getent group gpio >/dev/null 2>&1; then
    SVX_GROUPS+=(gpio)
fi
for g in "${SVX_GROUPS[@]}"; do
    if getent group "$g" >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
        info "Adding $USER to $g (requires sudo)"
        $SUDO /usr/sbin/usermod -aG "$g" "$USER" || warn "could not add $USER to $g"
    fi
done
ok "groups ensured: ${SVX_GROUPS[*]}"

# 7. Linger — a repeater must survive SSH logout; without linger the
# user bus (and every systemd --user unit) dies with the last session.
section "systemd-user linger"
if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    info "Enabling linger for $USER (requires sudo)"
    $SUDO loginctl enable-linger "$USER"
fi
ok "linger enabled"
# Re-establish the user bus if linger was just enabled; defensive nudge.
systemctl --user daemon-reload || true

# 8. Cgroup delegation. Looks limit-related, is NOT: podman's
# --cgroups=split (what Quadlet generates) creates a libpod-payload
# cgroup under the unit and enables its controllers; when user@'s
# delegated set lacks `pids`, crun aborts container CREATE with
# "controller `pids` is not available" (exit 126) and the unit
# crashloops at BOOT — observed 2026-07-30 on the e2e harness after a
# reboot, where the first boot had delegated controllers but the next
# one came up with an empty subtree_control chain. Modern systemd
# defaults usually delegate pids+memory to user@, so most hosts never
# notice; the drop-in turns "usually" into an invariant. Idempotency:
# keyed on the delegated set actually visible in the user slice, so a
# host that already delegates never prompts for sudo.
section "Cgroup delegation"
USER_SLICE="/sys/fs/cgroup/user.slice/user-$(id -u).slice"
NEED_DELEGATE_FIX=0
if [[ -f "$USER_SLICE/cgroup.controllers" ]]; then
    USER_SLICE_CTL=$(cat "$USER_SLICE/cgroup.controllers" 2>/dev/null || echo "")
    if grep -qw memory <<<"$USER_SLICE_CTL" && grep -qw pids <<<"$USER_SLICE_CTL"; then
        ok "user slice has memory + pids delegated"
    else
        NEED_DELEGATE_FIX=1
    fi
else
    # No user slice file yet — shouldn't happen post-linger, but treat
    # as missing so the override file at least lands on disk.
    NEED_DELEGATE_FIX=1
fi
if (( NEED_DELEGATE_FIX )); then
    DELEGATE_CONF="/etc/systemd/system/user@.service.d/delegate.conf"
    info "Writing $DELEGATE_CONF (requires sudo)"
    $SUDO install -d -m 0755 "$(dirname "$DELEGATE_CONF")"
    $SUDO tee "$DELEGATE_CONF" >/dev/null <<'EOF'
# Installed by svxlink-universal-installer.
# Guarantees user@.service delegates the controllers rootless podman's
# --cgroups=split needs to create container payload cgroups at boot
# (missing `pids` -> crun exit 126 crashloop before svxlink ever runs).
[Service]
Delegate=cpu cpuset io memory pids
EOF
    $SUDO systemctl daemon-reload
    ok "Installed $DELEGATE_CONF"
    # daemon-reload doesn't re-apply Delegate= to the already-running
    # user@.service instance; delegation lands on the next login/boot.
    warn "cgroup delegation takes effect on the next reboot/re-login."
fi

# 9. Journald: persistent storage + size cap. This is deliberately the
# only OTHER system drop-in this installer writes. The signalk
# reference installs more; each remaining one is omitted on purpose:
#   - No user podman.socket: nothing in this stack consumes the podman
#     API socket (no engine containers, no in-container podman) — which
#     also deletes the entire pause-namespace-realignment dance the
#     long-lived socket service needed.
#   - No TasksMax drop-in: it capped podman.service (the API service we
#     don't run).
#   - No user@.service.d/nofile.conf: that was QuestDB-specific.
section "Journald retention drop-in"
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/svxlink.conf
# Storage=persistent (not just the size cap): without it, a Pi whose
# journald defaults to volatile keeps the journal in RAM only, so a
# crash-before-logfile-open is undiagnosable after reboot — conmon
# routes container stdout to the journal, and that journal must survive.
# Capped at 200M (not the reference's 500M): the svxlink FILE log under
# ~/.svxlink/log is the primary record here, the journal is the
# secondary copy. An uncapped journal on an SD card fills the card.
JOURNALD_DESIRED='# Installed by svxlink-universal-installer
[Journal]
Storage=persistent
SystemMaxUse=200M
MaxRetentionSec=14day'
# Plain `cat` (no $SUDO) so the no-op re-run never prompts for a
# password. This works because the drop-in is written world-readable
# 0644 below — plain config with no secrets, matching stock
# /etc/systemd/journald.conf. A 0600 file would make this read fail for
# the unprivileged user and re-apply (re-prompting sudo) every run.
if [[ "$(cat "$JOURNALD_DROPIN" 2>/dev/null)" == "$JOURNALD_DESIRED" ]]; then
    ok "journald persistent + capped already applied (skipping)"
else
    info "Enabling persistent journal, capped to 200M / 14 days (requires sudo)"
    $SUDO install -d -m 0755 /etc/systemd/journald.conf.d
    # 2755, group systemd-journal — matches what journald/systemd-tmpfiles
    # create for /var/log/journal. Pass -g only when the group exists
    # (`install -g <missing>` errors and set -e would abort).
    if getent group systemd-journal >/dev/null 2>&1; then
        $SUDO install -d -m 2755 -g systemd-journal /var/log/journal
    else
        $SUDO install -d -m 2755 /var/log/journal
    fi
    printf '%s\n' "$JOURNALD_DESIRED" | $SUDO install -m 0644 /dev/stdin "$JOURNALD_DROPIN"
    $SUDO systemctl restart systemd-journald
    ok "journald persistent + capped applied"
fi

# Host state skeleton. log/ must exist (host-user-owned) before the
# first container start — it's the rw bind source for /var/log/svxlink;
# sounds/ is the per-language override root the renderer scans.
mkdir -p "$SVX_HOME/log" "$SVX_HOME/sounds" "$SNAP_DIR" "$PAYLOAD_DIR"

# 9. Image pull
section "Server image"
# Reclaim dangling (<none>) layers BEFORE pulling. Re-installs re-pull
# the rolling :latest/:master tags; when a tag's digest has moved, the
# prior digest's layers are orphaned but never reclaimed, and on slow
# SD/eMMC the per-layer commit `podman pull` does under the store lock
# crawls — the "Copying blob …" phase appears to hang for minutes.
# Dangling-only prune is safe: it never touches an image a container
# references (the rollback image keeps its tag/digest reference).
if [[ -n "$(podman images -f dangling=true -q 2>/dev/null)" ]]; then
    info "reclaiming dangling image layers from prior installs"
    podman image prune -f >/dev/null 2>&1 || true
fi
# Bound the pull. A stalled pull (slow store, registry hiccup) otherwise
# hangs the installer forever. `timeout` exits 124 on expiry;
# --retry/--retry-delay cover transient registry failures (they do NOT
# shorten a slow-but-progressing pull — that is what the timeout bounds).
info "pulling $IMAGE"
pull_rc=0
timeout 900 podman pull --retry 3 --retry-delay 5s "$IMAGE" || pull_rc=$?
if [[ "$pull_rc" -eq 124 ]]; then
    err "pulling $IMAGE did not finish within 900s."
    err "On a Pi this is usually a bloated rootless image store on slow SD"
    err "storage making layer commit crawl. Check and reclaim with:"
    err "    podman system df"
    err "    podman image prune -a -f   # then re-run this installer"
    err "If the store is small, the registry path may be at fault — retry, or"
    err "    podman pull --log-level=debug $IMAGE   # to see where it stalls"
    exit 1
elif [[ "$pull_rc" -ne 0 ]]; then
    err "pulling $IMAGE failed (podman exit $pull_rc)."
    err "Inspect the error above; retry, or for detail:"
    err "    podman pull --log-level=debug $IMAGE"
    exit 1
fi
ok "image pulled"

# 10. Config seed. seed-config.sh extracts the image's pristine
# /etc/svxlink (podman create + cp — seed and binaries can never skew)
# ONLY when ~/.svxlink/etc/svxlink.conf is absent, then applies the
# SVX_* answers (env, or TTY prompts on first run) via its awk set_ini.
# The EchoLink password reaches it by plain env inheritance — it is
# never placed on an argv line anywhere in this repo.
section "Config seed"
bash "$HERE/seed-config.sh" seed --image "$IMAGE"

# 11. Host CLI tools + payload — installed BEFORE any container start so
# the operator always has `svx bug-report` / `svx recover` when a later
# step fails, and so the hardware wizard below can delegate to `svx`.
section "Host CLI tools"
bash "$HERE/install-recovery-script.sh"
INSTALLER_VERSION="$INSTALLER_VERSION" bash "$HERE/install-svx-command.sh"

# Stage the payload: the renderer + detectors + templates + dashboard
# build context that make `svx render-server` / `svx dashboard install`
# work on an existing box with no installer tree present. Refreshed by
# `svx self-update`. Modes match that refresh (0755 scripts, 0644 data;
# lib/*.sh are sourced, never executed, so 0644).
install -m 0755 "$HERE/render-server-quadlet.sh" "$PAYLOAD_DIR/render-server-quadlet.sh"
install -m 0755 "$HERE/detect-hardware.sh" "$PAYLOAD_DIR/detect-hardware.sh"
install -m 0755 "$HERE/seed-config.sh" "$PAYLOAD_DIR/seed-config.sh"
mkdir -p "$PAYLOAD_DIR/lib"
for f in "$HERE"/lib/*.sh; do
    install -m 0644 "$f" "$PAYLOAD_DIR/lib/$(basename "$f")"
done
install -m 0644 "$HERE/../../quadlets/svxlink-server.container.template" \
    "$PAYLOAD_DIR/svxlink-server.container.template"
install -m 0644 "$HERE/../../quadlets/svxlink-dashboard.container.template" \
    "$PAYLOAD_DIR/svxlink-dashboard.container.template"
mkdir -p "$PAYLOAD_DIR/dashboard"
for f in Containerfile config.php.tmpl dash_config.php.seed talkgroups.json.seed; do
    install -m 0644 "$HERE/../../dashboard/$f" "$PAYLOAD_DIR/dashboard/$f"
done
ok "payload staged in $PAYLOAD_DIR"

# System-wide `svx` symlink for instant availability. The PATH snippet
# below only takes effect in NEW shells — this script is a child process
# and can't modify the invoking shell's PATH. /usr/local/bin is on PATH
# in every default shell already. The symlink TARGET stays
# ~/.local/bin/svx: that's the file `svx self-update` rewrites, so
# updates keep working through the link. The readlink guard keeps no-op
# re-runs sudo-free (same principle as the journald drop-in).
SVX_LINK=/usr/local/bin/svx
SVX_CLI="$HOME/.local/bin/svx"
if [[ "$(readlink "$SVX_LINK" 2>/dev/null)" == "$SVX_CLI" ]]; then
    ok "$SVX_LINK already links to $SVX_CLI"
elif [[ -e "$SVX_LINK" && ! -L "$SVX_LINK" ]]; then
    warn "$SVX_LINK exists and is not a symlink — leaving it alone."
    warn "'svx' will resolve via ~/.local/bin in new shells instead."
elif $SUDO ln -sfn "$SVX_CLI" "$SVX_LINK"; then
    ok "linked $SVX_LINK -> $SVX_CLI"
else
    warn "could not create $SVX_LINK; 'svx' available in new shells via ~/.local/bin"
fi

# PATH snippet: Debian's /etc/profile.d adds ~/.local/bin to PATH only
# when the directory existed at login time — it was created just now, so
# future shells would miss `svx`/`svx-recovery` without this. Written to
# BOTH ~/.profile and the login-shell rc because bash's startup file
# priority differs by mode (interactive non-login sources ~/.bashrc
# directly; login shells source ~/.profile). The guarded snippet is
# idempotent so duplication is harmless.
PATH_GUARD='# svxlink-universal-installer: ensure ~/.local/bin on PATH'
write_path_snippet() {
    local rc=$1
    if [[ -f "$rc" ]] && grep -Fq "$PATH_GUARD" "$rc"; then
        ok "PATH snippet already present in $rc"
        return
    fi
    # shellcheck disable=SC2016
    # $PATH / $HOME are written literally on purpose — the user's shell
    # expands them at login, not us here.
    {
        echo
        echo "$PATH_GUARD"
        echo 'case ":$PATH:" in'
        echo '    *":$HOME/.local/bin:"*) ;;'
        echo '    *) export PATH="$HOME/.local/bin:$PATH" ;;'
        echo 'esac'
    } >>"$rc"
    ok "Added PATH snippet to $rc"
}
write_path_snippet "$HOME/.profile"
case "$(basename "${SHELL:-bash}")" in
    zsh)  write_path_snippet "$HOME/.zshrc" ;;
    bash) write_path_snippet "$HOME/.bashrc" ;;
esac
PATH_NEEDS_RELOAD=0
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH_NEEDS_RELOAD=1 ;;
esac

# Container DNS self-heal (svxlink-resolv-watch.path/.service): podman
# snapshots /etc/resolv.conf once per container CREATE, so a boot that
# beats DHCP leaves the container with an empty resolver forever — and
# EchoLink directory login then fails permanently until a restart. The
# unit content lives in the svx CLI as the single owner; install the
# units by calling the command installed just above.
if ! "$HOME/.local/bin/svx" resolv-watch; then
    warn "could not install the svxlink-resolv-watch units; a boot that beats"
    warn "DHCP may leave EchoLink's directory login failing until a restart."
fi

# 12. Hardware detection + optional wizard
section "Hardware detection"
# Fresh detection re-emits defaults; a re-run of the installer (the
# documented way to refresh) must not clobber the operator's stored
# audio/PTT choices. hardware_merge (lib/hardware-merge.sh, shared with
# its test) carries the operator-decided fields forward and lets the
# fresh device lists (serial, gpio chips) win.
HW_FRESH=$("$HERE/detect-hardware.sh")
if command -v jq >/dev/null 2>&1 && [[ -s "$SVX_HOME/hardware.json" ]]; then
    HW_MERGED=$(hardware_merge "$SVX_HOME/hardware.json" <(printf '%s' "$HW_FRESH") 2>/dev/null) \
        && [[ -n "$HW_MERGED" ]] && HW_FRESH="$HW_MERGED"
fi
printf '%s\n' "$HW_FRESH" >"$SVX_HOME/hardware.json"
ok "wrote $SVX_HOME/hardware.json (operator choices preserved)"

# Park logic sides whose audio HALF is missing. Detection sets audio.rx
# only from a CAPTURE-capable card and audio.tx only from a
# playback-capable one — "a card exists" is not "a card can record": a
# Pi's onboard bcm2835/HDMI is playback-only, and the pristine config's
# Rx1 on it crashloops svxlink with "Open capture audio device failed"
# (bit the first real Pi 4 install, 2026-07-30; the all-or-nothing
# variant of this guard shipped first and missed exactly that case).
# Parking is PER SIDE: rx-less hosts still announce (TX via the onboard
# jack), deviceless hosts park both. `svx audio` re-attaches Rx1/Tx1
# when real hardware is configured. Only the untouched defaults are
# rewritten — an operator's explicit RX/TX choice survives re-runs.
_active_logic=$(sed -n 's/^LOGICS=//p' "$SVX_HOME/etc/svxlink.conf" 2>/dev/null | head -1 | cut -d, -f1)
if [[ -n "$_active_logic" ]]; then
    _cur_rx=$(sed -n "/^\[$_active_logic\]/,/^\[/{s/^RX=//p}" "$SVX_HOME/etc/svxlink.conf" | head -1)
    _cur_tx=$(sed -n "/^\[$_active_logic\]/,/^\[/{s/^TX=//p}" "$SVX_HOME/etc/svxlink.conf" | head -1)
    if ! printf '%s' "$HW_FRESH" | grep -q '"rx": {' && [[ "$_cur_rx" == "Rx1" ]]; then
        bash "$HERE/seed-config.sh" set "$SVX_HOME/etc/svxlink.conf" "$_active_logic" RX NONE
        warn "no capture-capable sound card — $_active_logic parked on RX=NONE."
        info "After plugging the radio interface: run 'svx audio' (re-enables Rx1)."
    fi
    if ! printf '%s' "$HW_FRESH" | grep -q '"tx": {' && [[ "$_cur_tx" == "Tx1" ]]; then
        bash "$HERE/seed-config.sh" set "$SVX_HOME/etc/svxlink.conf" "$_active_logic" TX NONE
        warn "no playback-capable sound card — $_active_logic parked on TX=NONE."
    fi
fi

# Apply the detected AUDIO_DEV defaults to the seeded config — parking's
# other half: the pristine config says alsa:plughw:0, which on a Pi is
# the playback-only ONBOARD card even when a perfectly good USB radio
# interface sits at index 1. Only the pristine default is rewritten
# (never an operator/wizard choice), and only for the side detection
# actually found — so a fresh install with the USB card already plugged
# needs zero wizard interaction, the stated design goal. CARD= naming,
# never the index (USB numbering shifts across boots).
_hw_dev_for() {
    # $1 = rx|tx. jq when present (installed in step 5); grep fallback
    # matches the compact one-line object detect-hardware.sh emits.
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$HW_FRESH" | jq -r ".audio.$1.dev // empty" 2>/dev/null
    else
        printf '%s' "$HW_FRESH" | grep -o "\"$1\": {[^}]*}" | grep -o '"dev":"[^"]*"' | head -1 | cut -d'"' -f4
    fi
}
_cur_rx_dev=$(sed -n '/^\[Rx1\]/,/^\[/{s/^AUDIO_DEV=//p}' "$SVX_HOME/etc/svxlink.conf" | head -1)
_cur_tx_dev=$(sed -n '/^\[Tx1\]/,/^\[/{s/^AUDIO_DEV=//p}' "$SVX_HOME/etc/svxlink.conf" | head -1)
_det_rx_dev=$(_hw_dev_for rx)
_det_tx_dev=$(_hw_dev_for tx)
if [[ -n "$_det_rx_dev" && "$_cur_rx_dev" == "alsa:plughw:0" ]]; then
    bash "$HERE/seed-config.sh" set "$SVX_HOME/etc/svxlink.conf" Rx1 AUDIO_DEV "$_det_rx_dev"
    bash "$HERE/seed-config.sh" set "$SVX_HOME/etc/svxlink.conf" Rx1 CARD_SAMPLE_RATE 48000
    ok "Rx1 audio: $_det_rx_dev (detected; change with 'svx audio')"
fi
if [[ -n "$_det_tx_dev" && "$_cur_tx_dev" == "alsa:plughw:0" ]]; then
    bash "$HERE/seed-config.sh" set "$SVX_HOME/etc/svxlink.conf" Tx1 AUDIO_DEV "$_det_tx_dev"
    bash "$HERE/seed-config.sh" set "$SVX_HOME/etc/svxlink.conf" Tx1 CARD_SAMPLE_RATE 48000
    ok "Tx1 audio: $_det_tx_dev (detected; change with 'svx audio')"
fi

# The interactive audio/PTT wizard is `svx audio` / `svx ptt` — offered
# only when a real TTY exists. A bare `[[ -r /dev/tty ]]` passes when
# the node merely exists with no controlling terminal behind it, so we
# probe by actually opening it, in a subshell that can't take the
# script down. Non-interactive runs keep the safe defaults
# (PTT_TYPE=NONE) and get pointed at the wizards for later.
if ( exec 3<>/dev/tty ) 2>/dev/null; then
    printf '\n%sConfigure audio and PTT hardware now?%s\n' "$C_BOLD" "$C_RESET" >/dev/tty
    printf 'You can always do it later with: svx audio / svx ptt  [y/N] ' >/dev/tty
    read -r _hw_reply </dev/tty || _hw_reply=""
    case "$_hw_reply" in
        y | Y | yes | YES)
            "$HOME/.local/bin/svx" audio || warn "audio wizard did not complete — re-run with: svx audio"
            "$HOME/.local/bin/svx" ptt || warn "PTT wizard did not complete — re-run with: svx ptt"
            ;;
        *)
            info "Skipped. Configure later with: svx audio / svx ptt"
            ;;
    esac
else
    info "No TTY — skipping the hardware wizard (node starts with PTT_TYPE=NONE)."
    info "Configure later with: svx audio / svx ptt"
fi

# --- Write-discipline + diagnostics helpers (shared with the steps below) ---

snapshot_existing() {
    local name=$1
    local src="$QUADLET_DIR/$name"
    [[ -f "$src" ]] || return 0
    local ts
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    cp -p "$src" "$SNAP_DIR/${ts}-${name}"
}

atomic_write() {
    local target=$1
    local body=$2
    local tmp
    tmp=$(mktemp "${target}.XXXXXX")
    printf '%s\n' "$body" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

# Capture a failed unit's status + recent logs to stderr, indented.
#
# `podman logs` is the authoritative source, not `journalctl --user -u`:
# rootless podman/conmon writes the container's stdout/stderr to the
# journal under the CONTAINER identifier, which `journalctl --user -u
# <quadlet-unit>` does NOT surface — on a typical Pi it returns "No
# journal files were found" even with a persistent journal, so the
# actual svxlink startup output (the thing we need when a start times
# out) was invisible. The unit name maps 1:1 to the container name (the
# Quadlet sets ContainerName=<unit-without-.service>). Keep the journal
# line too — harmless, and occasionally carries systemd-side detail.
capture_unit_failure() {
    local unit=$1
    local ctr="${unit%.service}"
    {
        echo "--- systemctl --user status \"$unit\" ---"
        systemctl --user --no-pager --full status "$unit" 2>&1 || true
        echo
        echo "--- podman logs --tail 50 \"$ctr\" ---"
        podman logs --tail 50 "$ctr" 2>&1 || true
        echo
        echo "--- journalctl --user -n 50 -u \"$unit\" ---"
        journalctl --user --no-pager -n 50 -u "$unit" 2>&1 || true
    } | sed 's/^/    /' >&2
}

# A `systemctl --user start/restart` of a Type=notify (sdnotify=conmon)
# unit BLOCKS until conmon signals ready or TimeoutStartSec elapses,
# then returns non-zero on timeout. But non-zero != "down": on an
# SD-card host the container create can exceed the timeout, systemd
# KILLs it, and Restart=always silently retries — a later attempt
# succeeds in seconds. This polls the unit for a grace window so that
# transient, self-recovering case isn't reported as a failure.
# Short-circuits to 1 the moment the unit reaches `failed`
# (start-limit-hit or a crash that exhausted the burst) — Restart=always
# won't retry from there. Never aborts under set -e.
#   $1 unit   $2 grace-seconds   $3 (optional) health URL to also require
unit_recovered_within() {
    local unit=$1 secs=$2 health_url=${3:-}
    local start=$SECONDS active
    while (( SECONDS - start < secs )); do
        active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
        if [[ "$active" == "active" ]]; then
            if [[ -z "$health_url" ]] || curl -fsS -o /dev/null -m 5 "$health_url" 2>/dev/null; then
                return 0
            fi
        elif [[ "$active" == "failed" ]]; then
            return 1
        fi
        sleep 3
    done
    return 1
}

# A start that times out (Result: timeout, container KILLed) with no
# crashloop in the journal is, on SD-card hosts especially, almost
# always podman blocking on a DAMAGED or INCOMPLETE overlay layer — an
# interrupted image pull leaves a layer `podman run` can't mount, so
# conmon never signals ready. `podman system check --quick` reports this
# without mutating anything; if it finds trouble we print the exact
# operator-run, non-destructive-first repair recipe. We do NOT
# auto-repair: rewriting the rootless store unprompted mid-install is
# riskier than telling the operator what to run.
# Predicate return: 0 = damage found (recipe printed), 1 = store clean.
# Call sites need `|| true` because under `set -e` the bare 1 aborts.
warn_if_storage_damaged() {
    command -v podman >/dev/null 2>&1 || return 0
    local report
    report=$(podman system check --quick 2>&1) || true
    if printf '%s' "$report" | grep -qiE 'damaged layer|incomplete layer|layer content modified'; then
        warn "podman's image store has damaged/incomplete layers — the usual"
        warn "cause of a server start that times out without crash-looping"
        warn "(an interrupted image pull on slow SD-card storage). Recover with:"
        warn "    systemctl --user stop svxlink-server svxlink-dashboard"
        warn "    podman system check --repair && podman system prune -f"
        warn "    podman pull ${IMAGE}"
        warn "    systemctl --user start svxlink-server"
        warn "  If it still fails, the heavier reset (preserves ~/.svxlink, which"
        warn "  is bind-mounted): podman system reset -f  then re-run this installer."
        return 0
    fi
    return 1
}

# 13. Quadlet render + start
section "Quadlet render"
mkdir -p "$QUADLET_DIR"
# The renderer owns snapshot-before-write, the HARDWARE fenced block,
# the live-Image=/USER ADDITIONS splice and the byte-identical
# short-circuit. Run the STAGED copy (defaults point at
# ~/.svxlink/{hardware.json,payload/...}) — the exact same invocation
# `svx render-server` uses later, so install-time and steady-state
# renders cannot drift.
bash "$PAYLOAD_DIR/render-server-quadlet.sh"

# Realize the resolved image in the rendered quadlet. The renderer
# preserves the live Image= (OperatorIntent) by design and the template
# pins ghcr.io/...:latest — so a fresh install with SVX_CHANNEL and/or
# SVX_IMAGE_REPO set would otherwise pull the override but START the
# template default (bit the harness e2e: pull succeeded against the
# local registry, the unit crashlooped on the unpublished ghcr ref).
# $IMAGE already encodes OperatorIntent-first resolution (explicit
# channel > live Image= > repo default), so splicing on ANY mismatch is
# idempotent: on a plain re-run $IMAGE came FROM the live file and the
# compare is equal. awk ENVIRON[], never sed: the image ref must not be
# interpretable as sed replacement syntax.
cur_image=$(sed -n 's/^Image=//p' "$SERVER_QUADLET_FILE" 2>/dev/null | head -1 || true)
if [[ "$cur_image" != "$IMAGE" ]]; then
    info "setting image: $IMAGE (was: ${cur_image:-<none>})"
    snapshot_existing svxlink-server.container
    spliced=$(WANT_IMAGE="$IMAGE" awk '
        !done && /^Image=/ { print "Image=" ENVIRON["WANT_IMAGE"]; done = 1; next }
        { print }' "$SERVER_QUADLET_FILE")
    atomic_write "$SERVER_QUADLET_FILE" "$spliced"
fi
ok "quadlet at $SERVER_QUADLET_FILE"

systemctl --user daemon-reload
ok "daemon-reload OK"

# Echo a one-line reason describing how the running svxlink-server
# container differs from what this run rendered/pulled, or empty when
# they match. Truth source is the RUNNING container's .ImageName +
# .Image (resolved image ID), not quadlet text — file diffs are noisy
# (template tweaks, the operator-owned USER ADDITIONS block). The
# resolved-ID compare is what catches a moved rolling tag: `:latest`
# re-pulled to a new digest keeps the same tag string, and without it a
# re-run would leave the old container running — the bug this guard
# exists to prevent.
svxlink_server_drift_reason() {
    podman container exists svxlink-server 2>/dev/null || { echo ""; return 0; }
    local state run_image run_id pulled_id
    state=$(podman inspect svxlink-server --format '{{.State.Status}}' 2>/dev/null || echo unknown)
    if [[ "$state" != "running" ]]; then
        echo "container state=$state"
        return 0
    fi
    run_image=$(podman inspect svxlink-server --format '{{.ImageName}}' 2>/dev/null || true)
    if [[ -n "$run_image" && "$run_image" != "$IMAGE" ]]; then
        echo "image: running=$run_image rendered=$IMAGE"
        return 0
    fi
    run_id=$(podman inspect svxlink-server --format '{{.Image}}' 2>/dev/null || true)
    pulled_id=$(podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || echo "")
    if [[ -n "$run_id" && -n "$pulled_id" && "$run_id" != "$pulled_id" ]]; then
        echo "image digest: running=${run_id:0:19} pulled=${pulled_id:0:19}"
        return 0
    fi
    echo ""
}

section "Starting svxlink-server"
# Log size BEFORE any start: the verify step proves liveness by the log
# file changing after a (re)start — svxlink has no HTTP surface, and the
# startup banner guarantees output the moment it comes up.
PRE_LOG_SIZE=$(stat -c '%s' "$SVX_LOG_FILE" 2>/dev/null || echo 0)
STARTED_THIS_RUN=0
start_server_unit() {
    # $1 = systemctl verb (start|restart)
    local verb=$1
    if systemctl --user "$verb" svxlink-server.service; then
        ok "svxlink-server ${verb}ed"
        return 0
    fi
    if unit_recovered_within svxlink-server.service 120; then
        # The blocking start returned non-zero — a start-timeout under
        # SD-card I/O contention, not a fault. Restart=always brought the
        # unit back. Common, self-healing; report it as recovery.
        ok "svxlink-server recovered after a slow start (SD-card I/O contention)"
        return 0
    fi
    warn "systemctl --user $verb svxlink-server.service failed and did not recover — capturing diagnostics:"
    capture_unit_failure svxlink-server.service
    warn_if_storage_damaged || true
    warn "continuing — 'svx bug-report' and 'svx recover' are installed for diagnosis"
    return 1
}
if ! systemctl --user is-active --quiet svxlink-server.service; then
    STARTED_THIS_RUN=1
    start_server_unit start || true
else
    # Already running (a re-run): restart only on observable drift so a
    # no-change re-run leaves the running node alone — `systemctl start`
    # on an active unit is a no-op and would never apply a new image.
    SK_DRIFT_REASON=$(svxlink_server_drift_reason)
    if [[ -n "$SK_DRIFT_REASON" ]]; then
        STARTED_THIS_RUN=1
        info "config changed: $SK_DRIFT_REASON"
        info "restarting svxlink-server.service to apply"
        start_server_unit restart || true
    else
        ok "svxlink-server matches the rendered quadlet (no restart needed)"
    fi
fi

# Reap superseded image layers now that the container runs the new one.
# The pre-pull prune cleared EARLIER installs' orphans; the layers this
# run supersedes only become dangling AFTER the container was recreated
# onto the freshly pulled image — which is now. Dangling-only, never
# `-a`: a prune that removed unused-but-TAGGED images would delete the
# previous server version kept as the rollback anchor. Best-effort.
if [[ -n "$(podman images -f dangling=true -q 2>/dev/null)" ]]; then
    info "Reclaiming image layers superseded by this install"
    podman image prune -f >/dev/null 2>&1 || true
fi

# 14. Dashboard — strictly opt-in (no license → the image is built
# locally on this host and never pushed; see docs/dashboard.md). The
# whole flow (clone at pinned SHA, seed configs, build, quadlet, start)
# is owned by `svx dashboard install`; the installer only delegates so
# there is exactly one implementation.
DASH_INSTALL=0
case "${SVX_DASHBOARD:-}" in
    1 | true | TRUE | yes | YES) DASH_INSTALL=1 ;;
esac
if (( DASH_INSTALL )); then
    section "Dashboard (SVX_DASHBOARD=1)"
    if SVX_DASH_PORT="$DASH_PORT" SVX_DASH_BIND="$DASH_BIND" \
        "$HOME/.local/bin/svx" dashboard install --non-interactive; then
        ok "dashboard installed"
    else
        warn "dashboard install failed — retry later with: svx dashboard install"
    fi
fi

# 15. Verify + record bootstrap state
section "Verify"
VERIFY_CORE_OK=1
if systemctl --user is-active --quiet svxlink-server.service; then
    ok "svxlink-server.service active"
else
    warn "svxlink-server.service is not active — see diagnostics above / 'svx recover doctor'"
    VERIFY_CORE_OK=0
fi
# In-container process probe. pgrep is guaranteed in the image (contract:
# procps in the diagnostics set). Retry briefly — right after a start the
# exec path can race container setup for a second or two.
SVX_PROC_OK=0
for _ in 1 2 3 4 5; do
    if podman exec svxlink-server pgrep -x svxlink >/dev/null 2>&1; then
        SVX_PROC_OK=1
        break
    fi
    sleep 2
done
if (( SVX_PROC_OK )); then
    ok "svxlink process running in the container"
else
    warn "could not confirm the svxlink process in the container (podman exec pgrep)"
    VERIFY_CORE_OK=0
fi
# Log-file liveness — the health primitive for a stack with no HTTP
# surface. Only meaningful right after a (re)start (the startup banner
# guarantees output); ambient log AGE is deliberately never a failure
# signal — idle repeaters legitimately log nothing for hours (contract).
# "Changed", not "grew": the entrypoint's rotation can shrink the file
# between samples; any change proves svxlink holds and writes the file.
log_changed_within() {
    local pre=$1 secs=$2
    local start=$SECONDS cur
    while (( SECONDS - start < secs )); do
        cur=$(stat -c '%s' "$SVX_LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$cur" != "0" && "$cur" != "$pre" ]]; then
            return 0
        fi
        sleep 2
    done
    return 1
}
if (( STARTED_THIS_RUN )); then
    if log_changed_within "$PRE_LOG_SIZE" 30; then
        ok "log file is live: $SVX_LOG_FILE"
    else
        warn "log file did not change within 30s of the start ($SVX_LOG_FILE)."
        warn "The image writes it via SVXLINK_LOGFILE (see the quadlet); check"
        warn "'podman logs svxlink-server' — it mirrors the same stream."
        VERIFY_CORE_OK=0
    fi
else
    if [[ -f "$SVX_LOG_FILE" ]]; then
        info "log file present; last activity: $(date -r "$SVX_LOG_FILE" 2>/dev/null || echo unknown) (age is informational — idle nodes log nothing for hours)"
    else
        warn "log file $SVX_LOG_FILE missing while the unit runs — check 'podman logs svxlink-server'"
        VERIFY_CORE_OK=0
    fi
fi

# Record bootstrap state: the VERIFY_MODE marker for re-runs and the
# rollback anchor `svx update` refines later. The digest is the pulled
# image's repo digest (falls back to the local ID when the registry ref
# is gone). jq preferred so re-run writes preserve fields other tools
# (svx update's previousImage) added; printf keeps the marker working
# on jq-less hosts.
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
IMG_DIGEST=$(podman image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null | head -1 || true)
[[ -n "$IMG_DIGEST" ]] || IMG_DIGEST=$(podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
TMP_LG=$(mktemp)
if command -v jq >/dev/null 2>&1; then
    if [[ -s "$LAST_GOOD" ]] && jq -e . "$LAST_GOOD" >/dev/null 2>&1; then
        jq --arg now "$NOW" --arg img "$IMAGE" --arg dig "$IMG_DIGEST" \
            '. + {updatedAt: $now, bootstrappedAt: $now, image: $img, digest: $dig}' \
            "$LAST_GOOD" >"$TMP_LG"
    else
        jq -n --arg now "$NOW" --arg img "$IMAGE" --arg dig "$IMG_DIGEST" \
            '{updatedAt: $now, bootstrappedAt: $now, image: $img, digest: $dig}' >"$TMP_LG"
    fi
else
    printf '{"updatedAt":"%s","bootstrappedAt":"%s","image":"%s","digest":"%s"}\n' \
        "$NOW" "$NOW" "$IMAGE" "$IMG_DIGEST" >"$TMP_LG"
fi
mv -f "$TMP_LG" "$LAST_GOOD"

# 15b. Verification pass (verify mode only): checkpoint sweep on re-runs.
# We don't classify "fixed" — every step is idempotent and doesn't say
# whether it had to do work. If a re-run leaves a checkpoint healthy the
# install is effectively repaired; what's still broken after a full pass
# is what the operator needs to see.
VERIFY_BROKEN=()
if [[ "$VERIFY_MODE" = "1" ]]; then
    section "Verification"
    VERIFY_HEALTHY=()
    verify_check() {
        local label=$1 verdict=$2
        if [[ "$verdict" = "ok" ]]; then
            VERIFY_HEALTHY+=("$label")
        else
            VERIFY_BROKEN+=("$label — $verdict")
        fi
    }
    if command -v podman >/dev/null 2>&1; then
        verify_check "podman binary" "ok"
    else
        verify_check "podman binary" "missing"
    fi
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        verify_check "systemd-user linger" "ok"
    else
        verify_check "systemd-user linger" "off; user-bus dies at logout"
    fi
    if [[ -f "$SERVER_QUADLET_FILE" ]]; then
        verify_check "Quadlet svxlink-server.container" "ok"
    else
        verify_check "Quadlet svxlink-server.container" "missing from $QUADLET_DIR"
    fi
    active=$(systemctl --user is-active svxlink-server.service 2>/dev/null || true)
    if [[ "$active" = "active" ]]; then
        verify_check "svxlink-server.service" "ok"
    else
        verify_check "svxlink-server.service" "state=${active:-unknown}; check 'podman logs svxlink-server'"
    fi
    if (( SVX_PROC_OK )); then
        verify_check "svxlink process (in-container pgrep)" "ok"
    else
        verify_check "svxlink process (in-container pgrep)" "not confirmed"
    fi
    # Log freshness is a checkpoint ONLY when this run restarted the
    # unit (banner guarantees output); otherwise a quiet log is healthy.
    if (( STARTED_THIS_RUN )); then
        if (( VERIFY_CORE_OK )) || [[ -f "$SVX_LOG_FILE" ]]; then
            verify_check "log file after restart" "ok"
        else
            verify_check "log file after restart" "no growth in $SVX_LOG_FILE"
        fi
    fi
    if [[ -x "$HOME/.local/bin/svx" && -x "$HOME/.local/bin/svx-recovery" ]]; then
        verify_check "svx + svx-recovery CLIs" "ok"
    else
        verify_check "svx + svx-recovery CLIs" "missing from ~/.local/bin"
    fi
    if [[ -x "$PAYLOAD_DIR/render-server-quadlet.sh" ]]; then
        verify_check "payload staged" "ok"
    else
        verify_check "payload staged" "missing $PAYLOAD_DIR/render-server-quadlet.sh"
    fi
    if [[ -f "$DASH_QUADLET_FILE" ]]; then
        live_dash_port=$(sed -n 's/^PublishPort=//p' "$DASH_QUADLET_FILE" 2>/dev/null | head -1 | cut -d: -f2 || true)
        [[ -n "$live_dash_port" ]] || live_dash_port="$DASH_PORT"
        if systemctl --user is-active --quiet svxlink-dashboard.service \
            && wait_for_http "http://127.0.0.1:${live_dash_port}/" 20; then
            verify_check "dashboard (:${live_dash_port})" "ok"
        else
            verify_check "dashboard (:${live_dash_port})" "unit inactive or not answering; check 'podman logs svxlink-dashboard'"
        fi
    fi
    if (( ${#VERIFY_HEALTHY[@]} > 0 )); then
        echo
        for item in "${VERIFY_HEALTHY[@]}"; do
            ok "$item"
        done
    fi
    if (( ${#VERIFY_BROKEN[@]} > 0 )); then
        echo
        warn "Verification flagged ${#VERIFY_BROKEN[@]} item(s):"
        for item in "${VERIFY_BROKEN[@]}"; do
            warn "  - $item"
        done
        echo
        warn "Next steps:"
        warn "  svx health           — quick re-check"
        warn "  svx recover doctor   — full diagnostics dump"
        warn "  svx bug-report       — bundle state for an issue"
    fi
fi

# 16. Summary. Most nodes are headless and the operator is on another
# machine on the same LAN, so resolve the primary outbound IP via
# `ip route get` (no packet is actually sent — the kernel just reports
# which source it would use); fall back to hostname -I, then localhost.
LAN_HOST=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
if [[ -z "$LAN_HOST" ]]; then
    LAN_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
DISPLAY_HOST="${LAN_HOST:-localhost}"

DASH_SUMMARY=""
if [[ -f "$DASH_QUADLET_FILE" ]]; then
    dash_pub=$(sed -n 's/^PublishPort=//p' "$DASH_QUADLET_FILE" 2>/dev/null | head -1 || true)
    dash_port="${DASH_PORT}"
    dash_bind="${DASH_BIND}"
    if [[ -n "$dash_pub" ]]; then
        dash_bind=$(cut -d: -f1 <<<"$dash_pub")
        dash_port=$(cut -d: -f2 <<<"$dash_pub")
    fi
    dash_host="$DISPLAY_HOST"
    [[ "$dash_bind" == "127.0.0.1" ]] && dash_host="127.0.0.1"
    DASH_SUMMARY="
  Dashboard  : http://${dash_host}:${dash_port}/  (NO authentication — keep it off the WAN)"
else
    DASH_SUMMARY="
  Dashboard  : not installed (optional) — add it with:  svx dashboard install"
fi

if [[ "$VERIFY_MODE" = "1" ]] && (( ${#VERIFY_BROKEN[@]} > 0 )); then
    SUMMARY_HEADLINE="${C_BOLD}Re-run complete — verification flagged ${#VERIFY_BROKEN[@]} item(s) above.${C_RESET}"
elif [[ "$VERIFY_MODE" = "1" ]]; then
    SUMMARY_HEADLINE="${C_GREEN}${C_BOLD}OK — existing install verified healthy.${C_RESET}"
elif (( VERIFY_CORE_OK )); then
    SUMMARY_HEADLINE="${C_GREEN}${C_BOLD}OK — the svxlink node is up.${C_RESET}"
else
    SUMMARY_HEADLINE="${C_BOLD}Install finished with warnings — see the Verify section above.${C_RESET}"
fi

cat <<EOF

${SUMMARY_HEADLINE}

  Image      : ${IMAGE}
  Config     : ~/.svxlink/etc/svxlink.conf   (svx config edit)
  Log        : ~/.svxlink/log/svxlink        (svx logs -f)${DASH_SUMMARY}

Note: svxlink stores the EchoLink password in PLAINTEXT in
~/.svxlink/etc/svxlink.d/ModuleEchoLink.conf (an svxlink requirement).
The directory is kept 0700 and the dashboard only ever sees a
sanitized copy with the password redacted.

The 'svx' command:
  svx health          node (and dashboard) health
  svx update          pull the current channel + restart, auto-rollback on failure
  svx channel         show/switch image channel (latest|master|<version>)
  svx audio / svx ptt audio + PTT hardware wizards
  svx logs -f         follow the svxlink log
  svx config edit     edit the config (snapshots first)
  svx dashboard       install/update/remove the web dashboard
  svx bug-report      bundle logs + state for an issue report
  svx help            full usage
EOF

# The /usr/local/bin symlink normally makes `svx` work in the CURRENT
# shell already — `command -v` re-checks rather than trusting the
# symlink branch, so the hint stays suppressed when an exotic PATH
# covers ~/.local/bin some other way.
if (( PATH_NEEDS_RELOAD )) && ! command -v svx >/dev/null 2>&1; then
    SHELL_NAME=$(basename "${SHELL:-bash}")
    cat <<EOF

To use 'svx' in this shell right now, run:  exec "${SHELL_NAME}" -l
(New logins pick it up automatically — the snippet was added to ~/.profile.)
EOF
fi
