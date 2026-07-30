#!/usr/bin/env bash
# Contract test for installer/linux/seed-config.sh — the INI backend of
# install.sh's config seeding and `svx config set`, plus the dashboard's
# credential sanitizer. Three surfaces:
#
#   1. `set FILE SECTION KEY VALUE`: idempotent (second run
#      byte-identical), section-scoped (the same KEY in another section
#      stays untouched — [SimplexLogic] and [RepeaterLogic] both carry
#      CALLSIGN in the pristine conf), creates a missing section at EOF,
#      preserves comments (a commented-out KEY line must never be treated
#      as the key).
#   2. `sanitize-echolink SRC DST`: PASSWORD= value becomes REDACTED and
#      every other byte is identical — the dashboard mounts DST, never the
#      real svxlink.d/, so the sanitizer is the security boundary.
#   3. `seed --etc DIR` with DIR already populated: the podman
#      create/cp path must be skipped ENTIRELY (asserted with a booby-
#      trapped podman stub on PATH) and the existing svxlink.conf must
#      not be clobbered; env-provided SVX_* answers still apply via
#      set_ini.
#
# No podman, no network. Run from the repo root.

set -euo pipefail

SEED=${SEED:-installer/linux/seed-config.sh}
if [[ ! -f "$SEED" ]]; then
    echo "[ERR] $SEED not found (run from repo root)" >&2
    exit 2
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- 1. set subcommand ---------------------------------------------------

ini="$tmp/svxlink.conf"
cat >"$ini" <<'EOF'
###############################################################################
# Global configuration
###############################################################################
[GLOBAL]
LOGICS=SimplexLogic
# The commented default below must survive every set:
#CALLSIGN=COMMENTED_OUT

[SimplexLogic]
TYPE=Simplex
CALLSIGN=MYCALL

[RepeaterLogic]
TYPE=Repeater
CALLSIGN=MYCALL
EOF

bash "$SEED" set "$ini" SimplexLogic CALLSIGN DL1ABC
if grep -qxF 'CALLSIGN=DL1ABC' "$ini"; then
    ok "set replaced CALLSIGN in [SimplexLogic]"
else
    miss "set did not replace CALLSIGN in [SimplexLogic]"
fi
# Section scoping: the identical key in [RepeaterLogic] must be untouched.
if awk '/^\[RepeaterLogic\]/{r=1} r && /^CALLSIGN=/{print; exit}' "$ini" \
    | grep -qxF 'CALLSIGN=MYCALL'; then
    ok "same KEY in the other section untouched (section-scoped)"
else
    miss "set leaked into [RepeaterLogic]"
fi
# Comments preserved: the commented-out CALLSIGN line is not a key.
if grep -qxF '#CALLSIGN=COMMENTED_OUT' "$ini"; then
    ok "commented-out KEY line preserved verbatim"
else
    miss "set consumed or rewrote a commented-out KEY line"
fi

# Idempotency: the second identical set must be a byte-identical rewrite.
before=$(sha "$ini")
bash "$SEED" set "$ini" SimplexLogic CALLSIGN DL1ABC
after=$(sha "$ini")
if [[ "$before" == "$after" ]]; then
    ok "second identical set is byte-identical"
else
    miss "second identical set changed bytes"
fi

# Missing section created at EOF.
bash "$SEED" set "$ini" NewSection NEW_KEY new_value
if awk '/^\[NewSection\]/{s=1} s && /^NEW_KEY=/{print; exit}' "$ini" \
    | grep -qxF 'NEW_KEY=new_value'; then
    ok "missing section created with the key"
else
    miss "missing section not created"
fi

# Section exists, key absent: appended inside that section (before the
# next header), not at EOF.
bash "$SEED" set "$ini" GLOBAL TIMESTAMP_FORMAT '"%a %b %e %H:%M:%S %Y"'
if awk '/^\[/{sec=$0} /^TIMESTAMP_FORMAT=/{print sec; exit}' "$ini" \
    | grep -qxF '[GLOBAL]'; then
    ok "new key lands inside its section, not at EOF"
else
    miss "new key landed outside [GLOBAL]"
fi

# File mode preserved across the rewrite (svxlink.conf must stay
# dashboard-readable; ModuleEchoLink.conf must stay 0600).
chmod 0600 "$ini"
bash "$SEED" set "$ini" GLOBAL LOGICS SimplexLogic
if [[ "$(stat -c '%a' "$ini")" == "600" ]]; then
    ok "file mode preserved across a set rewrite"
else
    miss "set changed the file mode to $(stat -c '%a' "$ini")"
fi

# --- 2. sanitize-echolink -------------------------------------------------

el_src="$tmp/ModuleEchoLink.conf"
cat >"$el_src" <<'EOF'
[ModuleEchoLink]
# EchoLink directory login
CALLSIGN=DL1ABC-L
PASSWORD=SuperSecret123
SYSOPNAME=Dirk
LOCATION=[Svx] Somewhere & 50% "special"
EOF
el_dst="$tmp/dashboard/ModuleEchoLink.conf"
bash "$SEED" sanitize-echolink "$el_src" "$el_dst"

if grep -qxF 'PASSWORD=REDACTED' "$el_dst"; then
    ok "PASSWORD value replaced by REDACTED"
else
    miss "PASSWORD not redacted"
fi
if grep -qF 'SuperSecret123' "$el_dst"; then
    miss "the secret leaked into the sanitized copy"
else
    ok "secret absent from the sanitized copy"
fi
# Every OTHER line byte-identical: the diff must touch exactly the
# PASSWORD line and nothing else (the dashboard parser needs the real
# section shape).
delta=$(diff "$el_src" "$el_dst" | grep -c '^[<>]' || true)
if [[ "$delta" == 2 ]]; then
    ok "diff touches exactly the PASSWORD line (all other bytes identical)"
else
    miss "sanitized copy differs beyond the PASSWORD line ($delta changed lines)"
fi
# 0644: www-data in the dashboard container maps to an unrelated subuid —
# only world-readable makes the ro bind mount readable, and the copy holds
# no secret precisely because of the redaction above.
if [[ "$(stat -c '%a' "$el_dst")" == "644" ]]; then
    ok "sanitized copy is 0644 (dashboard-readable)"
else
    miss "sanitized copy mode is $(stat -c '%a' "$el_dst"), want 644"
fi

# --- 3. seed-only-if-absent (podman path must be skipped entirely) -------

etc="$tmp/etc"
mkdir -p "$etc/svxlink.d"
conf="$etc/svxlink.conf"
# TIMESTAMP_FORMAT already at the forced value, byte-exactly as set_ini
# writes it, so an untouched re-seed must leave the file byte-identical.
cat >"$conf" <<'EOF'
[GLOBAL]
LOGICS=SimplexLogic
TIMESTAMP_FORMAT="%a %b %e %H:%M:%S %Y"

[SimplexLogic]
TYPE=Simplex
CALLSIGN=MYCALL
EOF
cat >"$etc/svxlink.d/ModuleEchoLink.conf" <<'EOF'
[ModuleEchoLink]
CALLSIGN=
PASSWORD=
EOF

# Booby-trapped podman: any invocation proves the seed path ran despite
# the pre-existing config — the exact clobber this subcommand must never
# risk. It records the call and fails hard.
stubbin="$tmp/bin"
mkdir -p "$stubbin"
cat >"$stubbin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >>"${PODMAN_MARKER:?}"
exit 1
EOF
chmod 0755 "$stubbin/podman"
marker="$tmp/podman-called"

before=$(sha "$conf")
if (PATH="$stubbin:$PATH" PODMAN_MARKER="$marker" \
    SVX_CALLSIGN='' SVX_LOGIC='' SVX_ECHOLINK_CALLSIGN='' SVX_ECHOLINK_PASSWORD='' \
    SVX_SYSOP_NAME='' SVX_TZ='' \
    bash "$SEED" seed --image ghcr.io/dirkwa/svxlink-server:latest \
        --etc "$etc" >"$tmp/seed1.log" 2>&1); then
    ok "seed over a populated --etc exited 0"
else
    miss "seed over a populated --etc failed:"
    sed 's/^/         /' "$tmp/seed1.log"
fi
if [[ -e "$marker" ]]; then
    miss "seed invoked podman although svxlink.conf already existed:"
    sed 's/^/         /' "$marker"
else
    ok "podman path skipped entirely (stub never invoked)"
fi
after=$(sha "$conf")
if [[ "$before" == "$after" ]]; then
    ok "existing svxlink.conf not clobbered (byte-identical)"
else
    miss "re-seed changed the existing svxlink.conf"
fi

# Env answers still apply on a populated tree (that's how a scripted
# re-run updates identity without clobbering the rest): LOGICS is
# switched and the callsign lands in the ACTIVE logic's section.
if (PATH="$stubbin:$PATH" PODMAN_MARKER="$marker" \
    SVX_CALLSIGN=DL1TEST SVX_LOGIC=Repeater SVX_ECHOLINK_CALLSIGN='' \
    SVX_ECHOLINK_PASSWORD='' SVX_SYSOP_NAME='' SVX_TZ='' \
    bash "$SEED" seed --image ghcr.io/dirkwa/svxlink-server:latest \
        --etc "$etc" >"$tmp/seed2.log" 2>&1); then
    ok "seed with env answers exited 0"
else
    miss "seed with env answers failed:"
    sed 's/^/         /' "$tmp/seed2.log"
fi
if grep -qxF 'LOGICS=RepeaterLogic' "$conf"; then
    ok "SVX_LOGIC=Repeater switched [GLOBAL] LOGICS"
else
    miss "SVX_LOGIC did not switch LOGICS"
fi
if awk '/^\[RepeaterLogic\]/{r=1} r && /^CALLSIGN=/{print; exit}' "$conf" \
    | grep -qxF 'CALLSIGN=DL1TEST'; then
    ok "callsign landed in the active logic section [RepeaterLogic]"
else
    miss "callsign did not land in [RepeaterLogic]"
fi
if awk '/^\[SimplexLogic\]/{s=1} /^\[RepeaterLogic\]/{s=0} s && /^CALLSIGN=/{print; exit}' "$conf" \
    | grep -qxF 'CALLSIGN=MYCALL'; then
    ok "inactive logic section untouched"
else
    miss "seed leaked the callsign into [SimplexLogic]"
fi
if [[ -e "$marker" ]]; then
    miss "env-answer pass invoked podman"
else
    ok "env-answer pass still skipped podman"
fi

if (( fail )); then
    echo
    echo "[ERR] seed-config contract broken — see entries above." >&2
    exit 1
fi
echo "[OK] set_ini semantics, sanitize-echolink, and seed-only-if-absent hold."
