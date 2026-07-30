# Installation

## Quick start

On a fresh Debian 13 (trixie) box — including Raspberry Pi OS (trixie) —
as a regular user with sudo:

```bash
curl -fsSL https://dirkwa.github.io/svxlink-universal-installer/installer/linux/install.sh | bash
```

The installer refuses to run as root: everything it creates is per-user
state (rootless podman, `systemctl --user` Quadlets, `~/.svxlink`). If your
box only has a root login, create a user first, give it sudo, and
**reconnect** as that user (the installer prints the exact recipe when it
refuses).

Debian 12 (bookworm) is hard-blocked: its Podman 4.x lacks the Quadlet
features this stack depends on. The installer prints a trixie upgrade
recipe. Linux only — there is no macOS/Windows path, because svxlink needs
real `/dev/snd`, hidraw PTT nodes, and GPIO chips that a VM cannot pass
through usefully.

## What the installer does

1. Preflight: RAM/disk checks, dashboard-port check, a warning if UDP
   5198/5199 (EchoLink) are already taken, cgroups v2 / Pi kernel-cmdline
   checks (a Pi cmdline patch asks for a reboot and continues on re-run).
2. Installs rootless podman (>= 5.3 enforced) + helpers, subuid/subgid
   ranges, adds you to `audio`, `dialout` (and `gpio` where it exists),
   enables linger so the node survives SSH logout, and drops a journald
   retention cap (persistent journal, 200 MB).
3. Pulls `ghcr.io/dirkwa/svxlink-server:<channel>` and seeds
   `~/.svxlink/etc/` from the image's pristine `/etc/svxlink` — **only if
   `svxlink.conf` is absent**; re-runs never clobber your config.
4. Applies your answers (callsign, logic, EchoLink credentials, sysop name,
   timezone) to the seeded config. PTT stays `NONE` until the wizard sets
   it — the node starts safely with no radio attached.
5. Runs the hardware wizard (audio card, PTT, squelch) — see
   [hardware.md](hardware.md).
6. Renders and starts the `svxlink-server` Quadlet, installs the `svx` CLI
   and `svx-recovery`, and stages the payload that lets `svx` re-render and
   update itself with no installer tree present.
7. Optionally installs the dashboard (only with `SVX_DASHBOARD=1` — the
   default is a hint pointing at `svx dashboard install`).
8. Verifies: unit active, svxlink process running in the container, the log
   file `~/.svxlink/log/svxlink` grew within 30 s (svxlink has no HTTP
   surface — the log file is the health primitive), dashboard answering if
   installed. Writes `~/.svxlink/last-good.json` as the rollback anchor.

## Environment variables

All optional; prompts cover the interactive path. For unattended installs:

| Variable | Default | Meaning |
|---|---|---|
| `SVX_CALLSIGN` | prompted | Node callsign (`MYCALL`). |
| `SVX_LOGIC` | `Simplex` | `Simplex` or `Repeater`. |
| `SVX_ECHOLINK_CALLSIGN` | unset | EchoLink callsign (e.g. `MYCALL-L`). Module enabled only when credentials are given. |
| `SVX_ECHOLINK_PASSWORD` | unset | EchoLink password. Export it in the environment — it is passed by inheritance, never on a command line (`ps` visibility). |
| `SVX_SYSOP_NAME` | unset | Sysop name. |
| `SVX_TZ` | from `/etc/timezone` | IANA timezone. |
| `SVX_CHANNEL` | `latest` | `latest`, `master`, or a version like `26.05.1`. Picks the tag for the very first pull AND the rendered `Image=` line. |
| `SVX_DASHBOARD` | unset | `1` installs the dashboard during bootstrap. |
| `SVX_DASH_PORT` | `8080` | Dashboard host port. Port 80 additionally writes a sysctl file lowering the unprivileged-port floor (its existence records your consent; re-runs don't re-prompt). |
| `SVX_DASH_BIND` | `0.0.0.0` | Dashboard bind address; use `127.0.0.1` behind a reverse proxy. |
| `SVX_NO_INSTALL_LOG` | unset | `1` disables the `~/.svxlink/install.log` tee. |
| `SVX_INSTALLER_BASE` | Pages URL | Override the fetch base (local mirrors / e2e testing). |

## Channels

The Quadlet's `Image=` tag is the channel: `:latest` (upstream releases),
`:master` (upstream snapshots), or a pinned version. `svx channel master`
switches (validated against GHCR) and immediately updates; `svx update`
stays on the current channel.

Note: the seeded config in `~/.svxlink/etc/` comes from the image the
installer pulled at bootstrap time (your `SVX_CHANNEL`). Upstream config
defaults move very rarely, but after switching channels across a major
upstream change, review `svx config` against the new image's pristine tree.

## Quadlet layout

| File | Unit | Notes |
|---|---|---|
| `~/.config/containers/systemd/svxlink-server.container` | `svxlink-server.service` | Host networking (EchoLink registers the observed UDP source; NAT breaks it). Contains two fenced regions: **USER ADDITIONS** (your hand edits, preserved across every re-render and update) and **HARDWARE** (rendered from `~/.svxlink/hardware.json` — do not edit there). |
| `~/.config/containers/systemd/svxlink-dashboard.container` | `svxlink-dashboard.service` | Only when the dashboard is installed. |

Ports: EchoLink uses UDP 5198/5199 inbound and TCP 5200 outbound — with
host networking nothing is "published"; just make sure your router forwards
UDP 5198–5199 if you want inbound EchoLink connections. The dashboard is
the only published port.

## EchoLink credentials at rest

svxlink requires the EchoLink password in plaintext in
`~/.svxlink/etc/svxlink.d/ModuleEchoLink.conf`. The installer keeps that
directory mode 0700, never mounts it into the dashboard (which gets a
sanitized copy with the password redacted), and `svx bug-report` redacts
`PASSWORD=` lines.

## Re-running

The installer is idempotent. On a box with a completed install
(`~/.svxlink/last-good.json` present) it runs a verification sweep instead:
podman version, linger, quadlets present, units active, log fresh after
restart, dashboard answering — and prints a healthy/broken list. Config,
hardware choices, and USER ADDITIONS are never touched.

## Uninstall

```bash
svx uninstall            # or, if the CLI itself is broken:
bash <(curl -fsSL https://dirkwa.github.io/svxlink-universal-installer/scripts/uninstall.sh)
```

Both stop and remove the units, quadlets, and containers, and remove the
locally-built dashboard image — and preserve `~/.svxlink` (config, logs,
snapshots), the pulled server images (rollback material), the CLI, the udev
rule, and the journald drop-in. The purge commands for a full wipe are
printed at the end.
