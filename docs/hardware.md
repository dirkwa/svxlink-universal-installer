# Hardware: audio, PTT, squelch

The hardware wizard runs during install and any time later as `svx audio` /
`svx ptt`. Detection lives in `detect-hardware.sh`, your confirmed choices
in `~/.svxlink/hardware.json`, and the renderer turns them into
`AddDevice=`/`Volume=` lines inside the server Quadlet's HARDWARE block.
Re-running detection never overrides a stored choice — only the wizard does.

## Group memberships

The installer adds your user to:

- `audio` — mandatory. `/dev/snd/*` nodes are `root:audio 0660`; rootless
  device access rides on your user's supplementary groups (the quadlet's
  `GroupAdd=keep-groups`), not on a uid mapping. This is also the group the
  PTT udev rule assigns to CM108 hidraw nodes.
- `dialout` — serial PTT (`/dev/ttyUSB*` is `root:dialout`).
- `gpio` — Raspberry Pi GPIO PTT/COS (`/dev/gpiochip*` is `root:gpio`);
  only added where the group exists.

Group changes take effect on the next login — the installer handles the
current session, but if you added groups manually, reconnect.

## Audio

- Cards are enumerated from `/proc/asound/cards`; devices are stored **by
  stable card id** (`plughw:CARD=Device,DEV=0`), never by index — USB card
  numbering shifts across boots.
- `plughw` (not raw `hw:`) with `CARD_SAMPLE_RATE=48000`: plughw does the
  resampling to svxlink's internal 16 kHz; raw `hw:` fails on cards that
  can't do the requested format natively.
- RX and TX are selected separately (two-card setups are common with cheap
  CM108 fobs); Enter reuses the RX card.
- The whole `/dev/snd` directory is passed through (`AddDevice=/dev/snd`),
  not individual nodes — child nodes recreated on a USB replug stay
  visible.

### PipeWire / PulseAudio conflicts

The number one "no audio in the container" cause: a desktop audio stack on
the host holds the card (EBUSY). The wizard detects this
(`systemctl --user is-active` + `fuser` on the chosen card's nodes) and
offers:

1. **Mask the host audio stack** (default — this is a dedicated repeater
   host): `systemctl --user mask --now pipewire pipewire.socket wireplumber
   pulseaudio.socket pulseaudio`.
2. **Per-card ignore** (desktop-preserving): a wireplumber config snippet
   excluding just the svxlink card.

The choice is recorded in `hardware.json` so re-runs don't re-prompt. The
wizard refuses to proceed with busy nodes — svxlink would start and pass
health checks but hear nothing.

## PTT

| Type | Selected via | svxlink.conf result | Notes |
|---|---|---|---|
| CM108 hidraw | wizard menu (C-Media devices matched by HID vendor id) | `PTT_TYPE=Hidraw`, `HID_DEVICE=/dev/svxlink-ptt`, `HID_PTT_PIN=GPIO3` (pin 1-4 per your fob's wiring) | Requires the udev rule below — hidraw nodes are `root:root 0600`, no group, so group membership alone can never help. |
| Serial RTS/DTR | `/dev/serial/by-id/*` picker | `PTT_TYPE=SerialPin`, `PTT_PORT=<by-id path>`, `PTT_PIN=RTS\|DTR` (`!` prefix inverts) | Always the by-id path, never `/dev/ttyUSB0` (renumbering). A replug needs `svx restart` — the device is resolved at container start. |
| Raspberry Pi GPIO | `gpiodetect`/`gpioinfo` picker | `PTT_TYPE=GPIOD`, `PTT_GPIOD_CHIP=/dev/gpiochipN`, `PTT_GPIOD_LINE=<line>` | gpiod only. The legacy sysfs GPIO interface is not offered — it is effectively impossible rootless. Pi 5 note: the RP1 chip naming/numbering differs from Pi 3/4; check `gpiodetect`. |
| None / VOX only | menu | `PTT_TYPE=NONE` | The install-time default; the node runs receive-only/EchoLink-only. |

### The CM108 udev rule

Written (with sudo) to `/etc/udev/rules.d/99-svxlink-ptt.rules`:

```
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0d8c", ATTRS{idProduct}=="<detected>", GROUP="audio", MODE="0660", SYMLINK+="svxlink-ptt"
```

It fixes both problems at once: group access (0660 + `audio`) and a stable
name (`/dev/svxlink-ptt`) that survives replug/renumbering. With more than
one CM108 present, the wizard pins the rule to the USB path (`KERNELS==`).
The wizard reloads udev and verifies the symlink appeared.

## Squelch

VOX is the default (`SQL_DET=VOX`) — works with any receiver, no wiring.
Hardware COS via GPIO or a serial pin uses the same pickers as PTT and
writes `[Rx1] SQL_DET=` accordingly. For CTCSS squelch and level
calibration (`siglevdetcal`), use `svx config` — that tuning is deliberately
manual.

## Real-time scheduling / audio xruns

The stack ships **without** RT privileges: granting them rootless means
`--cap-add SYS_NICE` plus rtprio ulimits, which weakens the container
posture for a problem most nodes don't have. If you hear periodic clicks or
see `alsa xrun` in `svx logs` under load (mostly small Pis with USB audio),
add to the **USER ADDITIONS** block of
`~/.config/containers/systemd/svxlink-server.container`:

```ini
# === BEGIN USER ADDITIONS ===
PodmanArgs=--cap-add=sys_nice --ulimit=rtprio=10:10
# === END USER ADDITIONS ===
```

then `systemctl --user daemon-reload && svx restart`. This is best-effort:
rootless RT depends on your host's rtprio limits (`ulimit -r`); raise them
via `/etc/security/limits.d/` if podman refuses. Hand edits in USER
ADDITIONS survive every re-render and update.

## Sound cards, sounds, and languages

Voice announcements come baked into the image (`en_US`). Other languages:
`svx sounds install de_DE <url-or-tarball>` unpacks into
`~/.svxlink/sounds/de_DE/` and re-renders the Quadlet with a read-only
mount over `/usr/share/svxlink/sounds/de_DE`. Per-language mounts only —
mounting the whole sounds tree would hide the baked pack and the TCL event
scripts.
