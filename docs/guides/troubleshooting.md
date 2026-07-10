# Troubleshooting

A quick symptom → cause → fix reference. Add `-v` /`--json` (see the end)
when you need more detail.

### `rpc call failed ...: permission denied` (EACCES on the socket)

**Cause:** the control socket is `0660 root:packetwyrm`.

**Fix:** run `pktwyrm` as root, or join the `packetwyrm` group. The CLI
prints the errno plus a hint. See [configuration.md](configuration.md).

### `rpc call failed ...: No such file or directory` / `socket path does not exist`

**Cause:** the daemon isn't running, or you pointed `--socket` at the
wrong path.

**Fix:** start the daemon and check `systemctl status packetwyrmd`. See
[installation.md](installation.md).

### No traffic / `rx_frames` stays 0 after `load`

**Cause:** the explicit-start model — loading a config does **not**
transmit.

**Fix:** run `pktwyrm test start` (or launch the daemon with
`-a`/`--autostart`). See [running-tests.md](running-tests.md).

### `pktwyrm load` printed `Configuration OK` but nothing changed on the daemon

**Cause:** that's `--check` / offline-validation output. A plain `load`
deploys by default, but `--check` only validates.

**Fix:** re-run without `--check`, and make sure the daemon is
reachable. See [cli-reference.md](cli-reference.md).

### Latency `min` shows a huge number (~27e9 ns) or the min column looks wrong

**Cause:** historic — with no samples the `min` was an uninitialized
sentinel. Current builds show `-` when a flow has no samples.

**Fix:** if you still see it, that flow received nothing — start
traffic. See [running-tests.md](running-tests.md).

### `config.load rejected: N flow rows requested but device supports M`

**Cause:** more measured flows than the bitstream implements (e.g. 33 on
a 32-flow build).

**Fix:** reduce measured flows, or mark some `background: true`
(TX-only). See [configuration.md](configuration.md).

### Unexplained per-port drops + red LED on a loopback

**Cause:** usually the host TAP's own IPv6 ND/MLD looped back and counted
as `rx_unmatched` — informational, **not** loss.

**Fix:** disable the relevant `punt:` protocols on the logical
interface, or ignore `rx_unmatched`. See
[configuration.md](configuration.md).

### Web GUI: 403 on actions

**Cause:** `POST /api/rpc` needs the `X-PW-Request: 1` header (the GUI
sends it; raw `curl` must add it) and an allow-listed `Host`. A
non-loopback proxyd bind also fail-closes without a daemon secret or
`insecure_no_auth`.

**Fix:** add the header / fix the Host, or configure auth. See
[web-gui.md](web-gui.md).

### Cross-card latency looks wrong / `servo_converged=false` at arm

**Cause:** the J5 GPIO time-sync servo hasn't locked yet.

**Fix:** wait a moment and re-arm (`test arm`). Tune with
`packetwyrmd -S`/`-C`. See [running-tests.md](running-tests.md).

### SFP optics metrics missing in Grafana

**Cause:** DAC / copper modules have no DOM.

**Fix:** optical power/temp only appear for a seated DOM-capable optical
SFP. See [monitoring.md](monitoring.md).

### `firmware update: backend open failed`

**Cause:** the card is bound to a running daemon or not to `vfio-pci`, or
you passed a bad BDF.

**Fix:** stop `packetwyrmd` and check the BDF. See
[firmware-update.md](firmware-update.md).

### Stale binary after editing a header

**Cause:** normally handled — the `sw` Makefile has `-MMD` dependency
tracking.

**Fix:** if unsure, do a clean `make -C sw`.

## Getting more detail

- Add `-v` to `packetwyrmd` for verbose daemon logging.
- `journalctl -u packetwyrmd` for the service log.
- Add `--json` to any CLI verb to see the exact fields.
