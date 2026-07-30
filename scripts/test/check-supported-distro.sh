#!/usr/bin/env bash
# Verifies is_supported_distro() in installer/linux/lib/distro.sh accepts
# exactly the tested matrix and rejects everything else.
#
# The function reads DISTRO_ID / DISTRO_CODENAME / DISTRO_VERSION
# (normally populated by detect_os from /etc/os-release). Here we set
# them directly and assert the verdict, so the test is host-independent —
# it never looks at the machine it runs on. (This mirrors the signalk
# reference test: no os-release fixture files, the vars ARE the
# interface.)
#
# Matrix under test — the podman >= 5.3 floor ([Quadlet]
# DefaultDependencies=false) drives every row:
#   * Debian/Raspbian: accepted only on codename "trixie" (the primary
#     svxlink target — repeater sites run Pi OS or plain Debian).
#     bookworm (podman 4.3.1, no usable Quadlet) must be rejected here;
#     preflight additionally hard-blocks it with an upgrade recipe.
#   * Ubuntu (all flavours share ID=ubuntu): VERSION_ID >= 25.04, where
#     the archive podman is >= 5.3. The EOL 24.x line (podman <= 5.0.3)
#     is rejected.
#   * Fedora: accepted regardless of version (ships podman 5.x).
#
# Run from the repo root.

set -euo pipefail

DISTRO_LIB=${DISTRO_LIB:-installer/linux/lib/distro.sh}

if [[ ! -f "$DISTRO_LIB" ]]; then
    echo "[ERR] $DISTRO_LIB not found (run from repo root)" >&2
    exit 2
fi

# shellcheck source=/dev/null
. "$DISTRO_LIB"

fail=0

# expect: "yes" => is_supported_distro should return 0; "no" => non-zero.
check() {
    local expect="$1" id="$2" codename="$3" version="$4" label="$5"
    # These are read by is_supported_distro in the sourced lib; shellcheck
    # can't see across the source boundary here.
    # shellcheck disable=SC2034
    DISTRO_ID="$id"
    # shellcheck disable=SC2034
    DISTRO_CODENAME="$codename"
    # shellcheck disable=SC2034
    DISTRO_VERSION="$version"
    local got
    if is_supported_distro; then
        got="yes"
    else
        got="no"
    fi
    if [[ "$got" == "$expect" ]]; then
        echo "[ OK ] $label -> $got"
    else
        echo "[FAIL] $label -> got $got, expected $expect" >&2
        fail=1
    fi
}

# expect  id       codename  version  label
check yes debian   trixie    13       "Debian 13 trixie"
check yes debian   trixie    13.1     "Debian 13.1 trixie point release"
check no  debian   bookworm  12       "Debian 12 bookworm (podman 4.3.1, no Quadlet)"
check yes raspbian trixie    13       "Raspberry Pi OS trixie"
check no  raspbian bookworm  12       "Raspberry Pi OS bookworm"
check no  debian   forky     14       "Debian 14 forky (untested — falls to the warn path)"

check no  ubuntu   noble     24.04    "Ubuntu 24.04 (EOL line, podman 4.9.3)"
check no  ubuntu   oracular  24.10    "Ubuntu 24.10 (EOL line, podman 5.0.3, below floor)"
check yes ubuntu   plucky    25.04    "Ubuntu 25.04 (podman 5.4.1)"
check yes ubuntu   questing  25.10    "Ubuntu 25.10 (podman 5.4.2)"
check yes ubuntu   resolute  26.04    "Ubuntu 26.04 (podman 5.7.0)"
check yes ubuntu   ""        27.04    "Future Ubuntu 27.04 (no codename present)"
# Ubuntu always uses YY.MM, but a dot-less VERSION_ID parses as
# major==minor (e.g. "25" -> 25*100+25=2525 >= 2504) and is accepted.
# Documenting that edge here so a parser change surfaces it.
check yes ubuntu   ""        25       "Ubuntu VERSION_ID without dot (edge case)"
# Flavours share ID=ubuntu; the codename is irrelevant to the version gate.
check yes ubuntu   questing  25.10    "Kubuntu 25.10 (same ID=ubuntu)"

# Unknown / malformed versions must not slip through.
check no  ubuntu   ""        ""       "Ubuntu with empty VERSION_ID"
check no  ubuntu   weird     rolling  "Ubuntu with non-numeric VERSION_ID"

# Fedora ships podman 5.x natively; version irrelevant to the gate.
check yes fedora   ""        40       "Fedora 40 Workstation/Server"
check yes fedora   ""        41       "Fedora 41 (CoreOS variant shares ID=fedora)"
check no  arch     ""        ""       "Arch (no version, untested)"

if (( fail )); then
    echo "[ERR] is_supported_distro matrix has regressions" >&2
    exit 1
fi
echo "[PASS] is_supported_distro matrix correct"
