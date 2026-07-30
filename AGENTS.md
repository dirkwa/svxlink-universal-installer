# svxlink-universal-installer

Bash bootstrap for a containerized [SvxLink](https://github.com/sm0svx/svxlink)
node (repeater / EchoLink) on Debian Trixie, including Raspberry Pi. Rootless
podman >= 5.3 + Quadlets, `curl … | bash` from GitHub Pages. This repo holds:

- The Linux installer under `installer/linux/` (there is no macOS/Windows
  installer — see the "Linux only" ADR below).
- Quadlet templates under `quadlets/`.
- The dashboard build recipe + config seeds under `dashboard/`.
- A standalone post-install health check (`scripts/doctor.sh`) and
  uninstaller (`scripts/uninstall.sh`).
- GitHub Pages publishes `installer/`, `quadlets/`, `dashboard/`, and
  `scripts/` so the one-liner and `svx self-update` just work.

The installer is a **one-shot bootstrapper**. After it finishes, systemd owns
the runtime and the `svx` CLI owns every mutation (updates, rendering,
health). The installer never runs continuously.

## Companion repo — the image contract is normative

| Repo | Role |
|---|---|
| [svxlink-images](https://github.com/dirkwa/svxlink-images) | Builds `ghcr.io/dirkwa/svxlink-server` (multi-arch, `:latest` releases + `:master` snapshots). |

**`docs/image-contract.md` in svxlink-images is the single source of truth**
for everything this repo assumes about the image: image name, tag scheme, env
names (`SVXLINK_CONF`, `SVXLINK_LOGFILE`, `SVXLINK_LOG_MAXSIZE`, `LC_ALL=C`),
root-in-userns user model, pristine `/etc/svxlink` seed tree, baked
`en_US` sounds path, single-`.1` rotation, labels. The tripwire is
`scripts/test/check-image-contract.sh --remote`: it fetches that repo's raw
contract doc + `entrypoint.sh` and greps our quadlet template against them —
deliberately NOT self-referential (an earlier design had both sides of the
grep in this repo, which is how three fatal contract drifts survived review).
Anything here touching env names, mount paths, or the image name must be
coordinated with an svxlink-images release.

## Architecture decisions (ADRs) — read before "fixing"

- **The CLI owns updates; there are no engine containers.** The SignalK
  reference stack runs updater/doctor containers with REST APIs; from its
  3-tier model this repo keeps tier 1 (= the `svx` CLI doing
  pull/render/restart/verify directly on the host) and tier 3
  (`svx-recovery` pure bash + `~/.svxlink/snapshots/`). Consequences that
  look like gaps but aren't: durable stop is `svx stop --durable`
  (`systemctl --user disable --now` — the CLI owns what SignalK delegated to
  the updater's WantedBy rewrite), and `svx self-update` refetches directly
  from Pages (no doctor-mediated refresh). Don't add engine containers back.

- **Container runs as root-in-userns; quadlet has NO `UserNS=`, only
  `GroupAdd=keep-groups`.** Rootless podman maps container uid 0 to the
  invoking host user: `~/.svxlink/{etc,log}` bind mounts stay host-user-owned
  with zero chown dances, and log files come out 0644 (root umask 022) —
  exactly what the dashboard's read path needs. `UserNS=keep-id` is rejected
  by ADR: combined with `--device` + `keep-groups` it produces
  `nobody:nobody` device nodes (podman#28364), and this stack is device-heavy
  (`/dev/snd`, hidraw PTT, gpiochips). Device access rides on the HOST user's
  supplementary groups (audio/dialout/gpio) via crun's keep-original-groups.
  The image side of this decision (no `USER` directive) is in the image
  contract.

- **`Network=host`, not pasta.** EchoLink registers the *observed* UDP source
  address with the directory server and embeds addressing in-protocol;
  pasta's NAT breaks symmetric 5198/5199 UDP. There is no port to publish on
  the server at all (5200/tcp is outbound). The dashboard container is the
  only one with a `PublishPort=`.

- **The dashboard image is built locally, never pushed.** The
  CN8VX/radioprj dashboard is "All rights reserved" — redistributing a built
  image is not licensed; building privately on the operator's host is. Hence
  `Image=localhost/svxlink-dashboard:local`, built by `svx dashboard install`
  from a clone of the fork at the pinned SHA (`DASHBOARD_PIN` in `svx.tmpl`).
  **Pin discipline**: third-party unreviewed code never floats — the pin only
  moves via an installer release that changes the constant, and
  `scripts/test/check-dashboard-pin-sync.sh` keeps `svx.tmpl` and
  `docs/dashboard.md` on the identical SHA. The dashboard is opt-in
  (`SVX_DASHBOARD=1` or `svx dashboard install`), never installed by default.

- **Linux only.** svxlink needs real `/dev/snd`, hidraw PTT nodes, and GPIO
  chips; a Podman Machine VM (the macOS/Windows path in the SignalK
  reference) cannot pass them through usefully. Don't scaffold
  `installer/macos` or `installer/windows`.

- **Deliberately omitted host tuning** (each looked "missing" to someone
  porting from the SignalK reference; every omission is intentional):
  - **No user `podman.socket`.** Nothing consumes the API socket — no engine
    containers, no in-container podman. This also deletes the entire
    pause-namespace-realignment dance (SignalK's step 15a): with no
    long-lived socket-activated `podman system service`, the sibling-userns
    bug has no victim.
  - **No `TasksMax=256` drop-in.** It capped `podman.service` (the API
    service), which we don't run.
  - **No `nofile.conf`.** That was QuestDB-specific in the reference stack.
  - **KEPT: `user@.service.d/delegate.conf` — but not for limits.** An
    earlier draft dropped it ("we set no Memory* limits"); the e2e harness
    then crashlooped at BOOT with `crun: controller 'pids' is not
    available` (exit 126): podman's `--cgroups=split` needs pids/memory
    delegated to user@ just to CREATE the container payload cgroup,
    limits or not. Modern systemd usually delegates them by default —
    the drop-in turns "usually" into an invariant. Do not remove it
    because "nothing sets limits"; that was the original mistake.
  - **Kept: the journald drop-in** (`/etc/systemd/journald.conf.d/svxlink.conf`,
    `Storage=persistent`, `SystemMaxUse=200M`, `MaxRetentionSec=14day`,
    written **0644** so the no-sudo content compare works — a 0600 file made
    the idempotency check re-prompt sudo every run in the reference repo).
    conmon routes container stdout to the journal; without persistence a
    crash-before-logfile-open on a Pi is undiagnosable after reboot. 200 MB
    not 500 MB: the file log is the primary record here.

## Things that look wrong but aren't — scars

- **`ExecStartPre=` (the DNS wait) lives under `[Service]`, never
  `[Container]`.** Quadlet rejects unknown keys per group: with the line in
  `[Container]` the generator refuses the whole unit and
  `systemctl --user start svxlink-server.service` reports "Unit not found"
  at first boot. `[Service]` is also semantically right — the wait must run
  against the HOST's resolv.conf before `podman run` snapshots it.
  `check-render-quadlet.sh` asserts no `Exec*`/`Restart*` keys inside
  `[Container]`.
- **Stdout mode passes NO `--logfile` flag at all.** `svxlink
  --logfile=/dev/stdout` silently loses every line when stdout is the conmon
  pipe (svxlink's logfile writer mishandles a pipe target — verified
  2026-07-30 against the real image); bare stdout streams fine and journald
  stamps the times. This is implemented in the image's entrypoint, but the
  scar is recorded here too so nobody "simplifies" the quadlet or docs into
  recommending `--logfile=/dev/stdout`.
- **Log freshness is `[INFO]`, never `[FAIL]`.** Idle repeaters legitimately
  log nothing for hours; an mtime-age health gate flaps every quiet night
  and — if ever reused in `svx update`'s verify — makes a healthy node
  auto-roll-back forever. Only **restart-scoped** growth checks may gate
  (startup banners guarantee output within seconds of a start). `svx health`,
  `scripts/doctor.sh`, and the image contract all state this; keep them
  agreeing.
- **The quadlet's `Image=` tag is OperatorIntent (the channel).** `:latest`
  and `:master` roll; a version tag pins; rollback pins a digest.
  Re-rendering therefore ALWAYS splices the live `Image=` line and the USER
  ADDITIONS inner lines out of the existing quadlet — via awk `ENVIRON[]`,
  never sed, so operator content with quotes/`%`/`&` can't corrupt the
  program — and refuses to touch the live file when the render looks
  malformed (missing `[Container]` header or `Image=` line).
- **Every `AddDevice=` source is `[ -e ]`-guarded with an `if`, not a
  short-circuit.** A `Volume=`/`AddDevice=` with a vanished source fails
  container create with exit 125 *before* the app starts (a bricked unit);
  and `[ -e ] && printf` leaves status 1 under `set -euo pipefail` in a pipe
  and aborts the whole render — both failure modes are inherited scars from
  the reference repo.
- **The dashboard mounts a SANITIZED `ModuleEchoLink.conf` copy**
  (`~/.svxlink/dashboard/ModuleEchoLink.conf`, `PASSWORD=` value replaced by
  `REDACTED`, regenerated by `seed-config.sh sanitize-echolink`), never the
  real `~/.svxlink/etc/svxlink.d/`. The real dir holds the plaintext
  EchoLink password (an svxlink constraint) and stays 0700 and out of the
  unauthenticated web container entirely.
- **No `START_*` environment variables anywhere.** Deliberate break with
  f4hlv/svxlink-docker (its sh supervisor kept the container "up" after
  svxlink crashed). One supervised process per container; `Restart=` owns
  recovery.
- **No `--pid=container:svxlink-server` on the dashboard.** It would make
  the dashboard's process-status LED honest, but hard-couples lifecycles:
  every `svx update` replacing the server container would tear down the
  dashboard's pid namespace and cascade a unit failure. Everything
  functional on the dashboard is log-derived; the LED degradation is
  cosmetic.
- **`hardware.json` merge carries operator choices with an explicit
  `has()`, not `//`.** jq's `//` treats a stored `false` as empty and would
  resurrect an operator's opt-out on the next detection run. Fresh
  `serial[]`/`gpio.chips` lists win (the device set may have changed).
- **Sound overrides mount per-language dirs only.** Mounting
  `/usr/share/svxlink` or `.../sounds` wholesale shadows `events.d/*.tcl`
  and the baked `en_US` pack (the f4hlv mistake). One
  `Volume=%h/.svxlink/sounds/<lang>:...:ro` per existing language dir.
- **Fetch manifests live between literal marker lines.**
  `install.sh` (`# BEGIN FETCH MANIFEST` / `# END FETCH MANIFEST`) and
  `svx.tmpl` (`# BEGIN SELFUPDATE MANIFEST` / `# END SELFUPDATE MANIFEST`)
  — `check-installer-manifest.sh` parses the markers and asserts every
  listed path exists (and that the self-update list stays a subset). Adding
  a payload file means touching the manifest(s), or CI fails.

## Filesystem invariants

Paths this repo's tooling creates and depends on:

| Path | Owner | Purpose | Written by |
|---|---|---|---|
| `~/.svxlink/etc/` | user (0700) | bind-mounted at `/etc/svxlink` (rw): `svxlink.conf`, `svxlink.d/`, `gpio.conf`, `node_info.json`, … | seeded once from the image's pristine tree (`podman create`+`cp`); then operator / `svx config` |
| `~/.svxlink/log/` | user (files 0644, container-written) | bind-mounted at `/var/log/svxlink` — rw in server, **ro** in dashboard; holds `svxlink` + exactly one `svxlink.1` | svxlink-server container |
| `~/.svxlink/sounds/<lang>/` | user | per-language voice-pack overrides, each mounted at `/usr/share/svxlink/sounds/<lang>:ro` | `svx sounds install` |
| `~/.svxlink/hardware.json` | user | audio/PTT/squelch OperatorIntent for the HARDWARE block | wizard (`svx audio` / `svx ptt`) via `detect-hardware.sh` + merge |
| `~/.svxlink/snapshots/` | user | `<UTC-ts>-<name>` copy of every file the tooling overwrites | `snapshot_existing()` |
| `~/.svxlink/last-good.json` | user | bootstrappedAt + last healthy image digest/tag — rollback anchor and VERIFY_MODE key | installer + `svx update` |
| `~/.svxlink/payload/` | user | staged renderer, templates, `detect-hardware.sh`, `seed-config.sh`, `lib/*.sh`, dashboard Containerfile + seeds — what makes `svx render-server`/`svx dashboard` work with no installer tree | installer + `svx self-update` |
| `~/.svxlink/dashboard-src/` | user | git clone of the dashboard fork at `DASHBOARD_PIN` (local build context) | `svx dashboard install/update` |
| `~/.svxlink/dashboard/` | user | `config.php`, `dash_config.php`, `talkgroups.json` (seeded-if-absent, then operator-owned) + the regenerated sanitized `ModuleEchoLink.conf` | `svx dashboard` + `svx config` hook |
| `~/.svxlink/install.log` | user | one run's installer output (truncated per run; `SVX_NO_INSTALL_LOG=1` opts out) | installer |
| `~/.config/containers/systemd/svxlink-server.container` | user | server quadlet; `Image=` tag = channel intent | renderer only |
| `~/.config/containers/systemd/svxlink-dashboard.container` | user | dashboard quadlet; presence = the dashboard opt-in record | `svx dashboard install` |
| `~/.config/systemd/user/svxlink-resolv-watch.{path,service}` | user | boot-beats-DHCP DNS heal | `svx resolv-watch` |
| `~/.local/bin/{svx,svx-recovery}` | user | the CLI + tier-2 recovery script | install scripts / `svx self-update` |
| `/usr/local/bin/svx` | root | symlink to `~/.local/bin/svx` (refused if a non-symlink sits there) | installer |
| `/etc/udev/rules.d/99-svxlink-ptt.rules` | root | CM108 hidraw GROUP/MODE + stable `SYMLINK+="svxlink-ptt"` | PTT wizard (sudo) |
| `/etc/systemd/journald.conf.d/svxlink.conf` | root (0644) | persistent journal, 200M cap | installer |
| `/etc/sysctl.d/80-svxlink-unprivileged-ports.conf` | root | only if the operator chose dashboard port 80; its existence = the durable "yes" | installer / `svx dashboard` |

Names: containers/units `svxlink-server`, `svxlink-dashboard`; label
namespace `io.svxlink.managed-by=svxlink-universal-installer`,
`io.svxlink.role={server,dashboard}`; the glob for
`systemctl --user list-units` / `podman ps --filter` / uninstall loops is
`svxlink-*`.

## Conventions

This repo is maintained by Dirk Wahrheit. Workflow is deliberate; AI tools
follow it strictly.

- Branch names use hyphens, never slashes: `fix-something`, `feat-something`.
- Angular conventional commits: `<type>(<scope>): <subject>`, types
  `feat|fix|docs|style|refactor|test|chore|perf`, subject <= 50 chars,
  imperative, no period.
- No `Co-Authored-By` lines, no "Generated with" attribution anywhere.
- Commit is not push: never push, merge, or create PRs without explicit
  approval. Never force-push unless asked.
- No emojis in commits, files, or comments.
- Bash strict mode (`set -euo pipefail`); `shellcheck -x`-clean and
  `bash -n`-clean (lint.yml enforces both over `.sh` and `.tmpl`).
- Dense why-comments naming the observed failure a line prevents — mirror
  the density of the SignalK reference repo; English only.
- PR bodies explain why; no checkboxes; a "Tested" section lists only what
  actually ran.

## Change recipes

- **Bump the dashboard pin**: review the upstream diff first (the code runs
  unauthenticated on operators' LANs), then change `DASHBOARD_PIN` in
  `installer/linux/svx.tmpl` AND the SHA in `docs/dashboard.md` in the same
  commit — `check-dashboard-pin-sync.sh` fails on any skew. Operators pick
  it up via `svx self-update` + `svx dashboard update`.
- **Add a payload/fetched file**: add the path inside install.sh's
  `# BEGIN FETCH MANIFEST` block; if `svx self-update` must refresh it too,
  also add it to svx.tmpl's `# BEGIN SELFUPDATE MANIFEST` block. Run
  `bash scripts/test/check-installer-manifest.sh`.
- **Touch quadlet env names, mounts, or the image name**: check
  `svxlink-images/docs/image-contract.md` first; if the contract moves, the
  change lands there in the same coordinated release, and
  `check-image-contract.sh --remote` must pass against the updated repo.
- **Add a hardware class to the HARDWARE block**: extend
  `render-server-quadlet.sh`'s `hardware_block()` + the `hardware.json`
  schema + `check-render-quadlet.sh` fixtures; keep every new `AddDevice=`
  source existence-guarded.
- **Add a contract test**: drop `scripts/test/check-<name>.sh`; lint.yml
  runs the whole glob, no registration needed.

## Verification

```bash
# Syntax + lint (what CI runs):
find installer scripts -type f \( -name '*.sh' -o -name '*.tmpl' \) -print0 | xargs -0 -n1 bash -n
find installer scripts -type f \( -name '*.sh' -o -name '*.tmpl' \) -print0 | xargs -0 shellcheck -x
for t in scripts/test/check-*.sh; do bash "$t"; done

# Contract tripwire against the real svxlink-images repo:
bash scripts/test/check-image-contract.sh --remote

# Renderer harness (no live system touched):
HARDWARE_JSON=scripts/test/fixtures/hidraw.json \
  TEMPLATE=quadlets/svxlink-server.container.template \
  OUTPUT=$(mktemp) bash installer/linux/render-server-quadlet.sh

# Local end-to-end against a fresh Trixie VM/container: serve the tree and
# point the bootstrap at it (both install.sh self-refetch and
# `svx self-update` honor the override):
python3 -m http.server 8000 &
SVX_INSTALLER_BASE=http://<host>:8000 bash installer/linux/install.sh
```
