# Recovery

This stack has **two** recovery tiers, ordered by ease of use. (The SignalK
sibling stack has three — this one deliberately runs no engine containers,
so there is no web recovery console; the CLI and a pure-bash script own
everything.)

1. **The `svx` CLI** — `svx update` verifies every update and rolls back
   automatically; `svx recover …` restores snapshots; `svx health` and
   `svx bug-report` diagnose.
2. **`~/.local/bin/svx-recovery`** — pure bash, zero containers required.
   The SSH safety net when `svx` itself (or podman) is broken.

Each tier is independent: `svx-recovery` needs nothing but bash and
systemd.

## Anatomy: where state lives

| Path | What's in it | Backed up by |
|---|---|---|
| `~/.svxlink/etc/` | svxlink config (`svxlink.conf`, `svxlink.d/` with the EchoLink credentials, …) | **you** — copy it somewhere; the recovery machinery here restores the *container stack*, not your radio config |
| `~/.svxlink/log/` | the svxlink log + one `.1` rotation sibling | not backed up (it's a log) |
| `~/.svxlink/hardware.json` | audio/PTT/squelch wizard choices | reproducible via `svx audio` / `svx ptt` |
| `~/.svxlink/snapshots/` | a `<UTC-timestamp>-<name>` copy of every file the tooling ever overwrote (quadlets, configs) | this IS the backup |
| `~/.svxlink/last-good.json` | bootstrap marker + the last image digest that passed verification — the rollback anchor | regenerated on each successful update |
| `~/.config/containers/systemd/svxlink-*.container` | the live Quadlets | mirror in `snapshots/` |
| `~/.local/bin/svx-recovery` | the host recovery script | re-installed by the installer / `svx self-update` |

## Automatic rollback (`svx update`)

Every `svx update`:

1. records the currently *running* image digest into `last-good.json`
   **before** touching anything,
2. pulls, restarts, then verifies: unit active, `svxlink` process running
   in the container, log file grew after the restart (startup banners
   guarantee output — this is restart-scoped on purpose; ambient log age is
   never a failure signal, idle repeaters log nothing for hours),
3. on failed verification, rewrites `Image=` to the digest-pinned previous
   image, restarts, and re-verifies — then reports loudly.

The rollback pin is deliberately sticky: a rolling tag would re-drift on
the next update. After investigating, `svx channel latest` (or `master`)
returns you to the channel. `--no-rollback` opts out for debugging.

## Scenario: an update or config change broke the node

```bash
svx health                        # what exactly is failing
svx logs                          # svxlink's own account
svx recover status                # unit states, live Image=, newest snapshots
svx recover rollback-server       # restore the server Quadlet from the newest snapshot
```

`rollback-server` copies the newest `~/.svxlink/snapshots/*-svxlink-server.container`
over the live Quadlet, `daemon-reload`s, and restarts. `rollback-dashboard`
and `rollback-all` do the same for the rest.

If a crashloop tripped the start limit (`StartLimitBurst=5` over 30
minutes), the unit sits in `failed` and `Restart=always` will not retry:

```bash
systemctl --user reset-failed svxlink-server.service
systemctl --user start svxlink-server.service
```

## Scenario: `svx` itself is broken

```bash
~/.local/bin/svx-recovery status
~/.local/bin/svx-recovery doctor         # units, containers, journal tails
~/.local/bin/svx-recovery rollback-all
```

A broken/deleted CLI is also recoverable by re-fetching it:
`svx self-update` if it still parses, otherwise the full one-liner below.
The standalone `scripts/uninstall.sh` on Pages mirrors `svx uninstall` for
the same reason — teardown must not depend on the CLI being intact.

## Scenario: snapshots gone / state corrupted

Re-run the installer:

```bash
curl -fsSL https://dirkwa.github.io/svxlink-universal-installer/installer/linux/install.sh | bash
```

It is idempotent — on a completed install it runs as a verification sweep
(VERIFY_MODE, keyed on `~/.svxlink/last-good.json`), repairs what's missing,
and **never clobbers** `~/.svxlink/etc/`, `hardware.json`, or your USER
ADDITIONS in the Quadlet. This one-liner is the recovery floor of last
resort; `svx self-update` prints it whenever a refresh fails.

## DNS after reboot (EchoLink won't log in)

Podman snapshots `/etc/resolv.conf` at container **create**. If the node
boots faster than DHCP populates DNS, the container may permanently lack a
nameserver — EchoLink directory login then fails forever while everything
else looks healthy. The server Quadlet waits up to 15 s for a nameserver
before starting; `svx resolv-watch` additionally installs a path unit that
heals the container whenever the host's resolv.conf changes. If EchoLink
login errors fill `svx logs` right after a reboot, run
`svx resolv-watch heal` once and consider installing the watch.

## Journald retention

The installer drops `/etc/systemd/journald.conf.d/svxlink.conf`
(`Storage=persistent`, `SystemMaxUse=200M`, `MaxRetentionSec=14day`) so a
Pi's SD card never fills with journal data, while crash output from before
the log file opens survives a reboot. If sudo was unavailable at install
time, apply it later:

```bash
sudo tee /etc/systemd/journald.conf.d/svxlink.conf >/dev/null <<EOF
[Journal]
Storage=persistent
SystemMaxUse=200M
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald
```

## What is NOT recoverable from these mechanisms

- **A wiped `~/.svxlink/etc/`.** Snapshots cover files the *tooling*
  rewrote; your radio config is only snapshotted when `svx config` touches
  it. Keep your own copy of `~/.svxlink/etc/` (it is small and plain-text —
  note it contains the EchoLink password).
- **The EchoLink password** if you lose the config — re-enter it via
  `svx config` (or re-run the installer with `SVX_ECHOLINK_PASSWORD` set).
