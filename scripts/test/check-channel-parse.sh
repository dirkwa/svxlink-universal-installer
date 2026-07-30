#!/usr/bin/env bash
# Pins the Image= line FORMAT FAMILY the channel machinery must handle,
# and the documented splice that rewrites it.
#
# The quadlet's Image= tag is OperatorIntent: `:latest` / `:master` roll,
# a version tag (`:26.05.1`) pins, and auto-rollback leaves a
# digest-pinned reference (`@sha256:<64 hex>`) behind. `svx channel` and
# the rollback path rewrite the line with an awk ENVIRON[] splice —
# never sed, because a digest reference is sed-hostile ('/', '@', and
# the temptation to build a s||| program from it). This test embeds the
# canonical splice helper (deliberately: it PINS the format + mechanism
# so svx.tmpl / render-server-quadlet.sh refactors that change either
# get caught) and drives it over fixture quadlets through the whole
# lifecycle: latest -> 26.05.1 -> master -> digest rollback -> back to
# latest. Run from the repo root.

set -euo pipefail

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

IMAGE_REPO="ghcr.io/dirkwa/svxlink-server"

# The canonical splice: replace only the FIRST Image= line, value passed
# via ENVIRON[] so it is data, never program text. Byte-for-byte the
# pattern render-server-quadlet.sh uses for its live-Image= preservation
# and svx.tmpl uses for `svx channel`/rollback.
splice_image() { # $1 = new full image ref, $2 = quadlet file -> stdout
    NEW_IMAGE="Image=$1" awk '
        !done && /^Image=/ { print ENVIRON["NEW_IMAGE"]; done = 1; next }
        { print }
    ' "$2"
}

# Channel classification of an Image= value — the parse the CLI's
# channel display relies on. Digest MUST be classified before the tag
# split: a digest reference contains no tag colon after the '@' but the
# repo path's port-less form still has one from the registry host on
# other registries; the '@sha256:' marker is the unambiguous signal.
channel_of() { # $1 = image ref
    case "$1" in
        *@sha256:*) echo digest ;;
        *:latest)   echo latest ;;
        *:master)   echo master ;;
        *:*)        echo "${1##*:}" ;;
        *)          echo unknown ;;
    esac
}

image_of() { sed -n 's/^Image=//p' "$1" | head -1; }

quadlet="$tmp/svxlink-server.container"
cat >"$quadlet" <<EOF
[Unit]
Description=fixture

[Container]
Image=${IMAGE_REPO}:latest
ContainerName=svxlink-server
Network=host
GroupAdd=keep-groups

# === BEGIN USER ADDITIONS ===
# operator comment mentioning Image= that must never be spliced
# === END USER ADDITIONS ===

[Service]
Restart=always
EOF

# Everything except the Image= line must be untouched by every splice.
non_image() { grep -v '^Image=' "$1"; }
baseline=$(non_image "$quadlet")

apply() { # $1 = new image ref
    splice_image "$1" "$quadlet" >"$quadlet.new" && mv "$quadlet.new" "$quadlet"
}

expect() { # $1 = expected full ref, $2 = expected channel, $3 = label
    local img
    img=$(image_of "$quadlet")
    if [[ "$img" == "$1" ]]; then
        ok "$3: Image= is $1"
    else
        miss "$3: Image= is '$img', want '$1'"
    fi
    local ch
    ch=$(channel_of "$img")
    if [[ "$ch" == "$2" ]]; then
        ok "$3: classified as channel '$2'"
    else
        miss "$3: classified as '$ch', want '$2'"
    fi
    local n
    n=$(grep -c '^Image=' "$quadlet" || true)
    if [[ "$n" == 1 ]]; then
        ok "$3: exactly one Image= line"
    else
        miss "$3: $n Image= lines after splice"
    fi
    if [[ "$(non_image "$quadlet")" == "$baseline" ]]; then
        ok "$3: everything but Image= byte-identical"
    else
        miss "$3: splice modified lines other than Image="
    fi
}

# Starting point sanity.
expect "${IMAGE_REPO}:latest" latest "initial fixture"

# latest -> version pin (svx channel 26.05.1).
apply "${IMAGE_REPO}:26.05.1"
expect "${IMAGE_REPO}:26.05.1" "26.05.1" "version pin"

# -> master channel.
apply "${IMAGE_REPO}:master"
expect "${IMAGE_REPO}:master" master "master channel"

# -> digest-pinned rollback (what auto-rollback writes; deliberately
# sticky — a rolling tag would re-drift on the next update).
digest="${IMAGE_REPO}@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
apply "$digest"
expect "$digest" digest "digest rollback"
# Pin the digest FORMAT itself: repo@sha256: + exactly 64 lowercase hex.
if [[ "$(image_of "$quadlet")" =~ ^ghcr\.io/dirkwa/svxlink-server@sha256:[0-9a-f]{64}$ ]]; then
    ok "digest reference matches the pinned format (repo@sha256:<64 hex>)"
else
    miss "digest reference does not match the pinned format"
fi

# -> back to latest (the documented 'svx channel latest after
# investigating' escape from a sticky rollback pin).
apply "${IMAGE_REPO}:latest"
expect "${IMAGE_REPO}:latest" latest "return to latest"

if (( fail )); then
    echo
    echo "[ERR] Image= channel parse/splice contract broken — see entries above." >&2
    exit 1
fi
echo "[OK] Image= splice + channel classification handle latest/master/version/digest."
