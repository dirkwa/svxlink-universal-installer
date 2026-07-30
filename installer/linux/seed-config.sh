#!/usr/bin/env bash
# seed-config.sh — first-run /etc/svxlink seeding + INI helpers.
#
# Subcommands:
#   seed --image IMAGE [--etc DIR]
#       Seed DIR (default ~/.svxlink/etc) from the image's pristine
#       /etc/svxlink via `podman create` + `podman cp` — ONLY when
#       DIR/svxlink.conf is absent, so a re-run can never clobber an
#       operator-edited config — then apply the SVX_* answers (env, or
#       TTY prompts on the seeding run) with set_ini.
#   set FILE SECTION KEY VALUE
#       Idempotent, section-scoped INI set (the `svx config set` backend).
#   sanitize-echolink SRC DST
#       Copy SRC to DST with the PASSWORD= value replaced by REDACTED.
#       DST is the ONLY ModuleEchoLink.conf the dashboard container may
#       ever mount — the real svxlink.d/ stays 0700 and out of it.
#
# Env consumed by `seed` (all optional): SVX_CALLSIGN,
# SVX_LOGIC=Simplex|Repeater, SVX_ECHOLINK_CALLSIGN,
# SVX_ECHOLINK_PASSWORD (reaches this script by plain env inheritance —
# it is never placed on an argv line and never echoed), SVX_SYSOP_NAME,
# SVX_TZ.
#
# Deliberately untouched in v1: PTT/RX/TX keys (the hardware wizard owns
# them; the pristine PTT_TYPE=NONE default keeps a wizard-less node
# start safe) and the logic's MODULES= list (enabling ModuleEchoLink in
# it is the operator's call via `svx config set`).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

# Section-scoped INI setter. awk, not crudini (not installed anywhere by
# default) and not sed (KEY/VALUE travel via ENVIRON[], so operator
# content with quotes/%/& can never be parsed as program text).
# Semantics: replace the first KEY= line inside [SECTION] (commented
# lines never match — comments are preserved verbatim); if the section
# exists without the key, append the key at the section's end; if the
# section is missing entirely, create it at EOF. Running it twice
# produces a byte-identical file (the idempotency `svx config set` and
# re-seeds rely on).
set_ini() {
    local file=$1 section=$2 key=$3 value=$4
    [[ -f "$file" ]] || : >"$file"
    local mode tmp
    # Preserve the file's mode across the rewrite: mktemp creates 0600,
    # and svxlink.conf must stay 0644 (the dashboard bind-mounts it ro)
    # while ModuleEchoLink.conf must stay 0600 (plaintext password).
    mode=$(stat -c '%a' "$file" 2>/dev/null || echo 644)
    tmp=$(mktemp "${file}.XXXXXX")
    INI_SEC="$section" INI_KEY="$key" INI_VAL="$value" awk '
        BEGIN {
            sec = ENVIRON["INI_SEC"]; key = ENVIRON["INI_KEY"]
            val = ENVIRON["INI_VAL"]
            in_sec = 0; done = 0; blanks = 0
        }
        # Blank lines inside the target section are BUFFERED, not printed
        # immediately: sections in the pristine conf end with a blank
        # separator line, and appending a new key after it would visually
        # detach the key from its section (it still parses, but every
        # human and diff reads it wrong). Buffering lets an appended key
        # land before the separator.
        /^\[/ {
            # Leaving the target section without having replaced the key:
            # append it at the section body end, before the separator.
            if (in_sec && !done) { print key "=" val; done = 1 }
            for (i = 0; i < blanks; i++) print ""
            blanks = 0
            in_sec = ($0 == "[" sec "]")
            print; next
        }
        {
            if (in_sec) {
                if ($0 ~ /^[ \t]*$/) { blanks++; next }
                if (!done) {
                    line = $0
                    sub(/^[ \t]+/, "", line)
                    # Literal-prefix match (no regex built from key —
                    # keys like TIMESTAMP_FORMAT are safe today, but a
                    # regex metachar in a future key must not change
                    # semantics). Commented lines never match: the "#"
                    # survives at position 1, so comments are preserved.
                    if (substr(line, 1, length(key)) == key) {
                        rest = substr(line, length(key) + 1)
                        if (rest ~ /^[ \t]*=/) {
                            for (i = 0; i < blanks; i++) print ""
                            blanks = 0
                            print key "=" val; done = 1; next
                        }
                    }
                }
                for (i = 0; i < blanks; i++) print ""
                blanks = 0
                print; next
            }
            print
        }
        END {
            if (in_sec && !done) { print key "=" val; done = 1 }
            for (i = 0; i < blanks; i++) print ""
            if (!done) {
                # Section absent — create it at EOF.
                print ""
                print "[" sec "]"
                print key "=" val
            }
        }
    ' "$file" >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$file"
}

# Copy an EchoLink module config with the password value stripped. awk
# sub() keeps every other byte (comments, spacing) identical so the
# dashboard's parser sees the real section shape; only the secret goes.
sanitize_echolink() {
    local src=$1 dst=$2
    [[ -f "$src" ]] || die "sanitize-echolink: source $src not found"
    mkdir -p "$(dirname "$dst")"
    local tmp
    tmp=$(mktemp "${dst}.XXXXXX")
    awk '
        /^[ \t]*PASSWORD[ \t]*=/ { sub(/=.*/, "=REDACTED") }
        { print }
    ' "$src" >"$tmp"
    # 0644: the dashboard container's www-data maps to an unrelated
    # subuid with no ownership relation to this file — world-readable is
    # what makes the ro bind mount actually readable, and the copy holds
    # no secret precisely because of the line above.
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dst"
}

# Actually OPEN /dev/tty to decide if we can prompt. A bare
# `[[ -r /dev/tty ]]` passes when the node merely exists but there is no
# controlling terminal behind it (curl|bash under some contexts) — then
# a real redirect fails with "No such device or address". Probe by
# opening it in a subshell that can't take the script down.
tty_usable() {
    ( exec 3<>/dev/tty ) 2>/dev/null
}

cmd_seed() {
    local image="" etc="${HOME}/.svxlink/etc"
    while (( $# )); do
        case "$1" in
            --image) image=${2:?--image needs a value}; shift 2 ;;
            --etc)   etc=${2:?--etc needs a value}; shift 2 ;;
            *) die "seed: unknown argument '$1'" ;;
        esac
    done
    [[ -n "$image" ]] || die "seed: --image IMAGE is required"

    local conf="$etc/svxlink.conf"
    local first_run=0
    if [[ ! -f "$conf" ]]; then
        first_run=1
        mkdir -p "$etc"
        info "Seeding $etc from the image's pristine /etc/svxlink"
        # `podman create` (never `run`): we only need the filesystem, and
        # the entrypoint must not execute. Seeding from the SAME image
        # that will run means seed and binaries can never skew.
        local cid=""
        cid=$(podman create "$image")
        if ! podman cp "$cid":/etc/svxlink/. "$etc"/; then
            podman rm "$cid" >/dev/null 2>&1 || true
            die "seed: podman cp from $image failed"
        fi
        podman rm "$cid" >/dev/null 2>&1 || true
        # svxlink.d holds ModuleEchoLink.conf, which stores the EchoLink
        # password in PLAINTEXT (svxlink requirement). 0700 keeps it off
        # every other read path; the dashboard only ever gets the
        # sanitized copy (sanitize-echolink).
        chmod 0700 "$etc/svxlink.d" 2>/dev/null || true
        # svxlink.conf carries no secrets after this seeding (EchoLink
        # creds land in svxlink.d) and the dashboard bind-mounts it ro
        # into a subuid-mapped Apache — it must be world-readable.
        chmod 0644 "$conf"
        ok "seeded pristine config into $etc"
    else
        ok "config already present at $conf (never clobbered on re-runs)"
    fi

    # Gather answers. Env wins; prompts happen only on the run that
    # actually seeded (first_run) AND only on a usable TTY — a re-run of
    # the documented curl|bash line must stay prompt-free.
    local callsign="${SVX_CALLSIGN:-}"
    local logic="${SVX_LOGIC:-}"
    local el_call="${SVX_ECHOLINK_CALLSIGN:-}"
    local el_pass="${SVX_ECHOLINK_PASSWORD:-}"
    local sysop="${SVX_SYSOP_NAME:-}"
    if (( first_run )) && tty_usable; then
        printf '\n%sNode identity — Enter keeps the current value/skips.%s\n' \
            "$C_BOLD" "$C_RESET" >/dev/tty
        if [[ -z "$callsign" ]]; then
            printf 'Callsign (e.g. DL1ABC): ' >/dev/tty
            read -r callsign </dev/tty || callsign=""
        fi
        if [[ -z "$logic" ]]; then
            printf 'Logic type (Simplex/Repeater) [Simplex]: ' >/dev/tty
            read -r logic </dev/tty || logic=""
        fi
        if [[ -z "$el_call" ]]; then
            printf 'EchoLink callsign (e.g. DL1ABC-L; Enter = no EchoLink): ' >/dev/tty
            read -r el_call </dev/tty || el_call=""
        fi
        if [[ -n "$el_call" && -z "$el_pass" ]]; then
            # -s: never echo; the value also never appears on an argv or
            # in install.log (set_ini passes it through awk ENVIRON).
            printf 'EchoLink password: ' >/dev/tty
            read -rs el_pass </dev/tty || el_pass=""
            printf '\n' >/dev/tty
        fi
        if [[ -z "$sysop" ]]; then
            printf 'Sysop name (Enter skips): ' >/dev/tty
            read -r sysop </dev/tty || sysop=""
        fi
    fi

    # Normalize/validate the logic choice; invalid values are ignored
    # rather than fatal (the pristine SimplexLogic default is safe).
    local logic_section=""
    case "$logic" in
        "") ;;
        Simplex | simplex | SIMPLEX)   logic_section="SimplexLogic" ;;
        Repeater | repeater | REPEATER) logic_section="RepeaterLogic" ;;
        *) warn "SVX_LOGIC='$logic' is not Simplex|Repeater — keeping the current LOGICS" ;;
    esac
    if [[ -n "$logic_section" ]]; then
        set_ini "$conf" GLOBAL LOGICS "$logic_section"
    fi

    # The callsign belongs to the ACTIVE logic section — read LOGICS
    # back (it may be a comma list; the first entry is the primary
    # logic) so an operator-customized LOGICS is honored.
    local active_logic
    active_logic=$(sed -n 's/^LOGICS=//p' "$conf" 2>/dev/null | head -1 || true)
    active_logic="${active_logic%%,*}"
    [[ -n "$active_logic" ]] || active_logic="SimplexLogic"
    if [[ -n "$callsign" ]]; then
        set_ini "$conf" "$active_logic" CALLSIGN "$callsign"
        ok "callsign $callsign set in [$active_logic]"
    fi

    # Forced, always (idempotent): the CN8VX dashboard parses log
    # timestamps with C-locale month-name regexes; the image bakes
    # LC_ALL=C and THIS format is the shape those regexes expect. An
    # operator restoring an old config gets it re-forced on the next
    # seed pass — it is load-bearing for the whole dashboard, not taste.
    set_ini "$conf" GLOBAL TIMESTAMP_FORMAT "\"%a %b %e %H:%M:%S %Y\""

    # EchoLink: only when BOTH credentials were given (a callsign
    # without password can't log into the directory and vice versa).
    local el_conf="$etc/svxlink.d/ModuleEchoLink.conf"
    if [[ -n "$el_call" && -n "$el_pass" ]]; then
        if [[ -f "$el_conf" ]]; then
            set_ini "$el_conf" ModuleEchoLink CALLSIGN "$el_call"
            set_ini "$el_conf" ModuleEchoLink PASSWORD "$el_pass"
            if [[ -n "$sysop" ]]; then
                set_ini "$el_conf" ModuleEchoLink SYSOPNAME "$sysop"
            fi
            # Plaintext password inside — clamp the file itself too, not
            # just the 0700 parent dir.
            chmod 0600 "$el_conf"
            ok "EchoLink credentials for $el_call applied (password not shown; stored in $el_conf)"
            info "Enable the module when ready:  svx config set svxlink.conf $active_logic MODULES ...,ModuleEchoLink"
        else
            warn "$el_conf missing from the seeded tree — EchoLink credentials NOT applied"
        fi
    elif [[ -n "$el_call$el_pass" ]]; then
        warn "EchoLink needs BOTH SVX_ECHOLINK_CALLSIGN and SVX_ECHOLINK_PASSWORD — skipping EchoLink setup"
    fi

    # SVX_TZ: there is no timezone key in svxlink.conf to set — the
    # container runs with Timezone=local (podman --tz=local), so
    # svxlink's clock-driven identification/TCL events follow the HOST
    # timezone. All we can honestly do here is flag a mismatch; changing
    # the host zone is a host-level (sudo) operation we don't hijack.
    if [[ -n "${SVX_TZ:-}" ]]; then
        local host_tz=""
        host_tz=$(cat /etc/timezone 2>/dev/null || true)
        if [[ -n "$host_tz" && "$host_tz" != "$SVX_TZ" ]]; then
            warn "SVX_TZ=$SVX_TZ differs from the host timezone ($host_tz)."
            warn "The container follows the host (Timezone=local); change it with:"
            warn "  sudo timedatectl set-timezone $SVX_TZ"
        fi
    fi
}

usage() {
    cat <<'EOF'
Usage:
  seed-config.sh seed --image IMAGE [--etc DIR]
  seed-config.sh set FILE SECTION KEY VALUE
  seed-config.sh sanitize-echolink SRC DST
EOF
}

case "${1:-}" in
    seed)
        shift
        cmd_seed "$@"
        ;;
    set)
        shift
        (( $# == 4 )) || { usage >&2; die "set needs exactly: FILE SECTION KEY VALUE"; }
        set_ini "$1" "$2" "$3" "$4"
        ;;
    sanitize-echolink)
        shift
        (( $# == 2 )) || { usage >&2; die "sanitize-echolink needs exactly: SRC DST"; }
        sanitize_echolink "$1" "$2"
        ;;
    -h | --help | help)
        usage
        ;;
    *)
        usage >&2
        die "unknown subcommand '${1:-}'"
        ;;
esac
