# PacketWyrm user guides

Task-oriented documentation for operators. (For internals, see
`../design/`.)

## Start here

- **[getting-started.md](getting-started.md)** — a 5-minute walkthrough with no
  FPGA required (fake backend).
- **[installation.md](installation.md)** — install the Debian package or build
  from source; run under systemd.

## Everyday use

- **[configuration.md](configuration.md)** — the environment config vs. the test
  config, the fields you set most, and `pktwyrm init`.
- **[running-tests.md](running-tests.md)** — the load → **start** → measure →
  stop workflow (traffic is off until you start it), one-shot `test run`, and
  reading loss / latency / jitter.
- **[cli-reference.md](cli-reference.md)** — every `pktwyrm` verb and flag.
- **[web-gui.md](web-gui.md)** — the browser GUI + the `packetwyrm-proxyd`
  gateway (including remote access and the frame preview).
- **[monitoring.md](monitoring.md)** — the Prometheus exporter and the bundled
  Grafana dashboard.

## Occasional / operations

- **[firmware-update.md](firmware-update.md)** — update the card bitstream.
- **[troubleshooting.md](troubleshooting.md)** — common errors and what they
  mean.

## Reference

- `../design/yaml-schema.md` — the full configuration schema.
- `../design/rpc-protocol.md` — the control-socket JSON RPC.
