#!/usr/bin/env bash
# Source me. GHCR tag helpers for ghcr.io/dirkwa/svxlink-server.
#
# Unlike the signalk reference — where latest_stable_tag() was stranded debug
# code after install-time pinning was reversed — this lib IS live code here:
# `svx channel <tag>` calls tag_exists() to validate the operator's requested
# tag before rewriting the Quadlet's Image= line, and `svx channel` (no arg)
# reports LatestAvailable via latest_stable_tag().
#
# A "stable" tag here is upstream sm0svx/svxlink's release shape YY.MM[.N]
# (26.05, 26.05.1). Channel/moving tags (latest, master, master-<sha7>,
# git-<sha7>) are filtered out so we report a release artefact, not a
# moving tip.
#
# We talk to the v2 distribution API directly rather than the GH Packages
# REST API because the latter requires auth even for public images. The
# anonymous bearer token from /token?scope= is enough for a public repo.

# Default repo path (the part after ghcr.io/). Kept as one constant so
# `svx channel` and the installer agree on the image contract's name.
SVX_GHCR_REPO_DEFAULT="dirkwa/svxlink-server"

# _ghcr_token REPO — print an anonymous pull token, or nothing on failure.
# -m 10 caps total time per call; if GHCR hangs we'd rather degrade than
# block a headless install/CLI for minutes.
#
# The `|| true` suffix is load-bearing: callers run under
# `set -euo pipefail`, and without it a curl failure OR an empty sed
# extraction would abort the whole caller before its own fallback logic
# could fire. This layer intentionally swallows all error detail — its
# contract is "print a token or nothing, never fail."
_ghcr_token() {
    local repo=$1
    curl -fsS -m 10 \
        "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" \
        2>/dev/null | \
        sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true
}

# latest_stable_tag [REPO] [FALLBACK] — print the highest YY.MM[.N]-shaped
# release tag for ghcr.io/<REPO> (default: the svxlink-server repo).
# Print FALLBACK (default "latest") on any failure path.
# Exit code: always 0 — the caller uses whatever we print for DISPLAY
# (LatestAvailable), never as an unvalidated pin.
latest_stable_tag() {
    local repo=${1:-$SVX_GHCR_REPO_DEFAULT}
    local fallback=${2:-latest}

    local token
    token=$(_ghcr_token "$repo")
    if [[ -z "$token" ]]; then
        echo "$fallback"
        return 0
    fi

    # tags/list returns {"name":"...","tags":[...]}. Pagination is via a
    # Link header, but this repo accumulates only a handful of release tags
    # per year (YY.MM cadence) plus the rolling channel tags, so the first
    # page is the whole list for years to come.
    local raw
    raw=$(curl -fsS -m 15 \
        -H "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${repo}/tags/list" \
        2>/dev/null) || true
    if [[ -z "$raw" ]]; then
        echo "$fallback"
        return 0
    fi

    # Extract the tags array contents, split on commas, filter to the
    # upstream YY.MM[.N] release shape. sort -V ranks 26.05 < 26.05.1 <
    # 26.11 correctly; tail -1 keeps the highest. `|| true` because grep
    # exits 1 when no release tags match (legitimate state — a brand-new
    # repo with only :master tags) and pipefail would otherwise abort the
    # caller.
    local latest
    latest=$(echo "$raw" | \
        sed -n 's/.*"tags":\[\([^]]*\)\].*/\1/p' | \
        tr ',' '\n' | \
        tr -d ' "' | \
        grep -E '^[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$' | \
        sort -V | \
        tail -1) || true
    if [[ -z "$latest" ]]; then
        echo "$fallback"
        return 0
    fi

    echo "$latest"
}

# tag_exists REPO TAG — HEAD the manifest for ghcr.io/<REPO>:<TAG>.
# Pass "" as REPO to use the default svxlink-server repo.
#
# Return codes let `svx channel` distinguish "you typo'd the tag" from
# "GHCR is unreachable" (the latter should warn, not hard-refuse a valid
# channel switch on a flaky repeater-site uplink):
#   0 — manifest exists (registry answered 200)
#   1 — registry answered 404: the tag definitively does not exist
#   2 — could not get a definitive answer (no token / timeout / 5xx)
tag_exists() {
    local repo=${1:-$SVX_GHCR_REPO_DEFAULT}
    local tag=$2

    local token
    token=$(_ghcr_token "$repo")
    [[ -z "$token" ]] && return 2

    # HEAD, not GET: we only need existence, not the manifest body. The
    # Accept list must cover both index (multi-arch) and single-manifest
    # media types — GHCR answers 404 for a tag it holds if the request
    # accepts none of the manifest's actual types. One comma-joined header
    # (the docker-CLI convention) rather than repeated -H lines.
    local code
    code=$(curl -sS -o /dev/null -I -m 15 \
        -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/${repo}/manifests/${tag}" \
        2>/dev/null) || true

    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;
    esac
}
