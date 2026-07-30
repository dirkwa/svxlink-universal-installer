#!/usr/bin/env bash
# Verifies the two fetch manifests against the repo (and, with --remote,
# against GitHub Pages).
#
# The curl-piped path (`curl -fsSL .../install.sh | bash`) downloads a
# hardcoded list of files into a tempdir before re-running install.sh from
# there, and `svx self-update` refetches a hardcoded subset of the same
# files straight from Pages. When a contributor adds a file the runtime
# depends on but forgets the manifest, local-clone installs keep working
# while the documented one-liner (or a later self-update) fails partway
# through. This script closes that gap by:
#
#   1. Parsing install.sh's array between the literal marker lines
#      "# BEGIN FETCH MANIFEST" / "# END FETCH MANIFEST" and asserting
#      every listed path exists in the repo.
#   2. Parsing svx.tmpl's "# BEGIN SELFUPDATE MANIFEST" /
#      "# END SELFUPDATE MANIFEST" block and asserting every listed path
#      exists AND is a subset of the fetch manifest's file set (plus
#      svx.tmpl / svx-recovery.tmpl themselves) — self-update can only
#      refresh what the installer knows how to fetch.
#   3. Scanning installer/linux/, quadlets/, dashboard/ for runtime files
#      that are NOT in the fetch list (the direction that bit the signalk
#      reference when a .tmpl shipped unlisted).
#   4. Optionally (--remote) HTTP-HEADing every fetch path against the
#      Pages base, expecting 200. Off by default in CI so we don't flake
#      on Pages-deploy races right after a merge. SVX_INSTALLER_BASE
#      overrides the base URL (the same env the bootstrap honors), so a
#      local `python3 -m http.server` e2e can be checked too.
#
# Exits non-zero on any inconsistency. Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}
SVX_TMPL=${SVX_TMPL:-installer/linux/svx.tmpl}
BASE_URL=${SVX_INSTALLER_BASE:-https://dirkwa.github.io/svxlink-universal-installer}
CHECK_REMOTE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) CHECK_REMOTE=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[ERR] unknown flag: $1" >&2
            exit 2
            ;;
    esac
    shift
done

for f in "$INSTALL_SH" "$SVX_TMPL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

# Extract the paths between two literal marker lines. Everything between
# the markers that isn't the array open/close or a comment is an entry;
# entries may be bare or double-quoted (install.sh uses bare paths,
# svx.tmpl quotes its array elements) — accept both so the two manifests
# don't need to share a style.
parse_manifest() {
    local file=$1 begin=$2 end=$3
    awk -v b="$begin" -v e="$end" '
        index($0, b) { inb = 1; next }
        index($0, e) { inb = 0 }
        inb { print }
    ' "$file" \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v -e '^#' -e '=($' -e '^)$' -e '^$' \
        | sed -e 's/^"//' -e 's/"$//'
}

mapfile -t fetch < <(parse_manifest "$INSTALL_SH" \
    "# BEGIN FETCH MANIFEST" "# END FETCH MANIFEST")
mapfile -t selfupdate < <(parse_manifest "$SVX_TMPL" \
    "# BEGIN SELFUPDATE MANIFEST" "# END SELFUPDATE MANIFEST")

if [[ ${#fetch[@]} -eq 0 ]]; then
    echo "[ERR] could not parse the FETCH MANIFEST out of $INSTALL_SH" >&2
    exit 2
fi
if [[ ${#selfupdate[@]} -eq 0 ]]; then
    echo "[ERR] could not parse the SELFUPDATE MANIFEST out of $SVX_TMPL" >&2
    exit 2
fi

echo "[i] parsed ${#fetch[@]} fetch path(s), ${#selfupdate[@]} self-update path(s)"

fail=0

# Check 1: every fetch entry must exist in the repo. Catches the "added
# an entry for a file we never created" direction.
echo
echo "[i] fetch manifest entries exist in the repo"
declare -A in_fetch=()
for p in "${fetch[@]}"; do
    in_fetch["$p"]=1
    if [[ -f "$p" ]]; then
        printf '  [OK]   %s\n' "$p"
    else
        printf '  [MISS] %s (in fetch manifest but not in repo)\n' "$p"
        fail=1
    fi
done

# Check 2: the self-update list must exist AND be a subset of the fetch
# set. svx self-update refetches from the same Pages tree the bootstrap
# uses; a self-update-only file would work on upgraded boxes but be
# absent from fresh installs — silent skew between the two populations.
# svx.tmpl / svx-recovery.tmpl are always legitimate self-update targets
# (they ARE the artifacts self-update exists to replace), so they're
# allowed even if a future manifest refactor drops them from the fetch
# list.
declare -A subset_ok=()
for p in "${!in_fetch[@]}"; do subset_ok["$p"]=1; done
subset_ok["installer/linux/svx.tmpl"]=1
subset_ok["installer/linux/svx-recovery.tmpl"]=1

echo
echo "[i] self-update manifest entries exist and are fetchable at install time"
for p in "${selfupdate[@]}"; do
    if [[ ! -f "$p" ]]; then
        printf '  [MISS] %s (in self-update manifest but not in repo)\n' "$p"
        fail=1
        continue
    fi
    if [[ -z "${subset_ok[$p]:-}" ]]; then
        printf '  [MISS] %s (in self-update manifest but NOT in the fetch manifest)\n' "$p"
        fail=1
    else
        printf '  [OK]   %s\n' "$p"
    fi
done

# Check 3: every runtime file in the repo must be in the fetch list.
# Patterns are conservative — the kinds of files install.sh re-runs,
# sources, or stages into ~/.svxlink/payload/. dashboard/ is scanned
# whole: everything under it is payload (Containerfile + config seeds).
declare -A allowlist=(
    # (none yet — every file under installer/linux/, quadlets/ and
    # dashboard/ is currently runtime-required by the curl-piped path.
    # Keep this short and commented so it doesn't become a parking lot.)
    [unused]=1
)
unset 'allowlist[unused]'

echo
echo "[i] runtime files in the repo are all listed"
while IFS= read -r -d '' p; do
    if [[ -n "${in_fetch[$p]:-}" ]]; then
        continue
    fi
    if [[ -n "${allowlist[$p]:-}" ]]; then
        printf '  [SKIP] %s (allowlisted)\n' "$p"
        continue
    fi
    printf '  [MISS] %s (in repo but not in fetch manifest)\n' "$p"
    fail=1
done < <(
    find installer/linux quadlets -type f \
        \( -name '*.sh' -o -name '*.tmpl' -o -name '*.template' \) -print0
    find dashboard -type f -print0
)

if (( CHECK_REMOTE )); then
    echo
    echo "[i] checking $BASE_URL"
    for p in "${fetch[@]}"; do
        # HEAD (-I) is enough — we only need the status, not the bytes.
        # Assign outside the substitution: curl prints its own status via
        # -w and ALSO exits non-zero on failure, so `|| echo 000` inside
        # would append. No -f: it makes curl exit non-zero on 4xx/5xx too,
        # so the fallback would overwrite a real 404 with "000" and the
        # diagnostic below would lose the status it exists to report.
        code=$(curl -sS -I -o /dev/null -w '%{http_code}' "${BASE_URL}/${p}") || code="000"
        if [[ "$code" == "200" ]]; then
            printf '  [%s] %s\n' "$code" "$p"
        else
            printf '  [%s] %s — not served at the base URL\n' "$code" "$p"
            fail=1
        fi
    done
fi

if (( fail )); then
    echo
    echo "[ERR] fetch/self-update manifests are inconsistent — see entries above." >&2
    exit 1
fi
echo
echo "[OK] fetch + self-update manifests are consistent."
