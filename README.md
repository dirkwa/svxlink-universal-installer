# SvxLink Universal Installer

One-command bootstrap for a containerized [SvxLink](https://github.com/sm0svx/svxlink)
node (simplex link, repeater, EchoLink) on Debian Trixie — including
Raspberry Pi. Rootless Podman + systemd Quadlets, a `svx` management CLI
with manual updates and automatic rollback, and an optional web dashboard.

```bash
curl -fsSL https://dirkwa.github.io/svxlink-universal-installer/installer/linux/install.sh | bash
```

The server image comes from the companion repo
[svxlink-images](https://github.com/dirkwa/svxlink-images)
(`ghcr.io/dirkwa/svxlink-server`, linux/amd64 + linux/arm64;
`:latest` = newest upstream release, `:master` = upstream snapshots).

## Requirements

- **Debian 13 (trixie)** or Raspberry Pi OS (trixie). Debian 12 (bookworm)
  is hard-blocked — its Podman 4.x lacks the Quadlet features this stack
  needs; the installer prints an upgrade recipe.
- A **regular user with sudo** (not root — everything runs rootless under
  your user; the installer refuses to run as root and prints the bootstrap
  recipe).
- **Linux only.** There is no macOS/Windows installer: svxlink needs real
  `/dev/snd` audio devices, hidraw PTT nodes, and GPIO chips, and a Podman
  Machine VM cannot pass them through usefully.
- Internet access to GHCR and GitHub Pages; ~3 GB free disk.

## What it installs

- `svxlink-server` — SvxLink in a rootless container, host networking
  (EchoLink needs the real UDP source address), `Restart=always`, config in
  `~/.svxlink/etc/`, logs in `~/.svxlink/log/`.
- The `svx` CLI (`~/.local/bin/svx`, symlinked to `/usr/local/bin/svx`) and
  the pure-bash `svx-recovery` safety net.
- A hardware wizard for audio (ALSA card selection), PTT (CM108 hidraw /
  serial / Raspberry Pi GPIO via gpiod), and squelch.
- Optionally (opt-in) the CN8VX web dashboard — see below.

The installer prompts for (or reads from env): callsign, logic type
(Simplex/Repeater), EchoLink credentials, sysop name, timezone. Re-running
it is safe: existing config is never clobbered, and a completed install
re-runs as a verification sweep. See
[docs/installation.md](docs/installation.md) for every knob
(`SVX_CALLSIGN`, `SVX_CHANNEL`, `SVX_DASHBOARD=1`, …).

## The `svx` command

| Command | What it does |
|---|---|
| `svx health` | Unit + in-container process + dashboard probes. Log age is informational only — idle repeaters log nothing for hours. |
| `svx update` | Pull the configured channel, restart, verify; **automatic rollback** to the last-good image digest on failure. |
| `svx channel [latest\|master\|<version>]` | Show or switch the image channel (validated against GHCR), then update. |
| `svx logs [-f]` | Tail the svxlink log file (`--dashboard` for the dashboard container). |
| `svx config [edit\|show\|set]` | Edit `svxlink.conf` and friends; snapshots before every write. |
| `svx audio` / `svx ptt` | Re-run the hardware wizards (card selection, PTT type, udev rule). |
| `svx sounds [list\|install <lang> <url>\|remove]` | Manage voice-pack overrides per language. |
| `svx render-server` | Re-render the server Quadlet from `hardware.json` (preserves your hand edits and the live image tag). |
| `svx dashboard [install\|update\|remove\|status]` | Manage the opt-in web dashboard. |
| `svx start` / `svx stop [--durable]` / `svx restart` | Service control; `--durable` survives reboots. |
| `svx recover …` | Snapshot rollback via the pure-bash recovery script. |
| `svx bug-report` | Diagnostic tarball (passwords redacted). |
| `svx self-update` | Refresh the CLI + payload from GitHub Pages. |
| `svx uninstall` | Remove units/containers; preserves all data. |

## Dashboard (opt-in)

`svx dashboard install` (or `SVX_DASHBOARD=1` at install time) sets up the
[CN8VX SvxLink dashboard (radioprj fork)](https://github.com/radioprj/SvxLink-Dashboard-V4.0-by-CN8VX)
on port 8080 (configurable), reading the node's log and a sanitized copy of
its EchoLink config.

- **License**: the dashboard is "All rights reserved" by its authors. Its
  image is therefore **built locally on your machine** from a pinned upstream
  commit and never published to any registry. SvxLink itself (GPL) and the
  voice packs are unaffected.
- **Security**: the dashboard has **no authentication**. It defaults to
  binding all interfaces so LAN devices can reach it — **never expose it to
  the internet** without an authenticating reverse proxy. The EchoLink
  password is never mounted into it.

Details, pinning, and configuration: [docs/dashboard.md](docs/dashboard.md).

## Updating

Updates are always manual — `svx update` pulls the channel your Quadlet's
`Image=` tag names, restarts, verifies the node came back (process + log
growth), and rolls back to the previous image digest automatically if it
did not. No timers, no background updaters.

## Documentation

- [docs/installation.md](docs/installation.md) — full walkthrough, env
  variables, re-running, channels, uninstall.
- [docs/hardware.md](docs/hardware.md) — audio cards, PTT (CM108 / serial /
  GPIO), squelch, PipeWire conflicts, real-time notes.
- [docs/dashboard.md](docs/dashboard.md) — dashboard install, license,
  configuration files.
- [docs/recovery.md](docs/recovery.md) — rollback and disaster recovery.

## License

Apache-2.0 (this repo's scripts and templates). The SvxLink software built
into the server image is GPL; the dashboard's separate license is discussed
in [docs/dashboard.md](docs/dashboard.md).
