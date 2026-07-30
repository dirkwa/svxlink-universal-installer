#!/usr/bin/env bash
# The dashboard fork pin exists in two places by necessity:
# `DASHBOARD_PIN` in installer/linux/svx.tmpl (what `svx dashboard
# install/update` actually checks out and builds) and the SHA documented
# in docs/dashboard.md (the operator-facing statement of what code runs
# unauthenticated on their LAN). The doc cannot source the CLI, so the
# value is duplicated — and a drifted pair would mean the docs describe
# a different third-party revision than the one being built. Third-party
# unreviewed code never floats: the pin only moves via a commit that
# changes BOTH files (see AGENTS.md change recipe); this check turns any
# skew into a CI failure. Run from the repo root.

set -euo pipefail

SVX_TMPL=${SVX_TMPL:-installer/linux/svx.tmpl}
DASH_DOC=${DASH_DOC:-docs/dashboard.md}

for f in "$SVX_TMPL" "$DASH_DOC"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0

# The constant must be a full 40-hex commit SHA — a branch name or an
# abbreviated SHA would reintroduce the floating-code problem the pin
# exists to prevent.
tmpl_pin=$(sed -n 's/^DASHBOARD_PIN="\([0-9a-f]\{40\}\)"$/\1/p' "$SVX_TMPL")
if [[ -z "$tmpl_pin" ]]; then
    echo "  [MISS] could not extract a 40-hex DASHBOARD_PIN=\"...\" from $SVX_TMPL"
    fail=1
else
    echo "  [OK]   svx.tmpl pin: $tmpl_pin"
fi

# The doc side: every 40-hex string in dashboard.md must be the same one
# SHA (grepping all of them catches a half-updated doc that mentions the
# old pin in one paragraph and the new one in another).
mapfile -t doc_pins < <(grep -oE '\b[0-9a-f]{40}\b' "$DASH_DOC" | sort -u)
if [[ ${#doc_pins[@]} -eq 0 ]]; then
    echo "  [MISS] no 40-hex SHA found in $DASH_DOC"
    fail=1
elif [[ ${#doc_pins[@]} -gt 1 ]]; then
    echo "  [MISS] $DASH_DOC mentions ${#doc_pins[@]} different 40-hex SHAs:"
    printf '         %s\n' "${doc_pins[@]}"
    fail=1
else
    echo "  [OK]   docs pin:     ${doc_pins[0]}"
fi

if [[ -n "$tmpl_pin" && ${#doc_pins[@]} -eq 1 && "$tmpl_pin" != "${doc_pins[0]}" ]]; then
    echo "  [MISS] DASHBOARD_PIN and docs/dashboard.md disagree"
    fail=1
fi

if (( fail )); then
    echo
    echo "[ERR] dashboard pin drift — update svx.tmpl and docs/dashboard.md together." >&2
    exit 1
fi
echo
echo "[OK] dashboard pin is in sync between svx.tmpl and docs/dashboard.md."
