# Web GUI

PacketWyrm ships a browser GUI served by a **separate gateway**,
`packetwyrm-proxyd`. The gateway terminates HTTPS, serves the static
GUI, and relays `POST /api/rpc` to the daemon's control socket. It
holds no state and understands no RPCs: the daemon (`packetwyrmd`)
stays the sole authority for authentication.

This guide is the operator walkthrough. For the architecture and the
security model (why the gateway is a separate process, how the CSP /
asset embedding / auth flow work), see
[../design/web-gui.md](../design/web-gui.md).

## Start the gateway

Packaged (reads `/etc/packetwyrm/proxyd.yaml`):

```sh
sudo systemctl enable --now packetwyrm-proxyd
```

Or run it directly:

```sh
packetwyrm-proxyd --config /etc/packetwyrm/proxyd.yaml
```

(you can also pass the individual options as CLI flags instead of a
config file). By default the gateway binds `127.0.0.1:8443` with a
self-signed TLS certificate, so out of the box it is reachable only
from localhost. Browse to <https://localhost:8443/>.

## The config file (`/etc/packetwyrm/proxyd.yaml`)

Every option can be set in a simple `key: value` file. CLI flags
override the file, and the systemd unit runs `--config` against this
path.

| Key | Meaning |
| --- | --- |
| `listen` | `ADDR:PORT` to bind (default `127.0.0.1:8443`). |
| `socket` | Daemon control socket (default `/run/packetwyrm/packetwyrmd.sock`). |
| `tls_cert` / `tls_key` | TLS cert/key files. Blank → auto self-signed cert. |
| `no_tls` | Serve plain HTTP. **Localhost / SSH-tunnel only.** |
| `insecure_no_auth` | Drop the fail-closed auth requirement (see below). |
| `allowed_hosts` | Comma-separated extra `Host:` header values to accept. |

Example:

```yaml
listen: "127.0.0.1:8443"
socket: "/run/packetwyrm/packetwyrmd.sock"
tls_cert: ""            # blank -> self-signed
tls_key: ""
allowed_hosts: "tester.lab.example"
```

## Reaching it remotely

Two options.

### SSH tunnel (recommended)

Keeps the GUI private on the tester and adds no network attack surface:

```sh
ssh -L 8443:127.0.0.1:8443 <host>
```

Then browse <https://localhost:8443/> on your workstation.

### LAN exposure

Bind a non-loopback address:

```yaml
listen: "0.0.0.0:8443"
```

A non-loopback bind **fails closed**: the gateway refuses to start
unless *either* the daemon has a `system.secret` configured *or* you
explicitly set `insecure_no_auth: true`. This prevents accidentally
publishing an unauthenticated control plane on the LAN.

When exposed, also:

- Set `allowed_hosts` to the exact hostname/IP that clients use. This
  is the anti-DNS-rebinding gate — the gateway rejects requests whose
  `Host:` header is not allow-listed.
- Replace the self-signed cert. Browsers will warn on the auto cert;
  either verify the SHA-256 fingerprint the gateway prints at startup,
  or supply a real `tls_cert` / `tls_key`.

### The two request gates

Every `POST /api/rpc` must pass two checks before it is relayed:

1. **`X-PW-Request: 1` header** (CSRF gate). The GUI and
   `pktwyrm --host` send it automatically; a raw `curl` must add it by
   hand:

   ```sh
   curl -H 'X-PW-Request: 1' ... https://<host>:8443/api/rpc
   ```

2. **Allow-listed `Host:`** (anti-rebinding gate), as configured with
   `allowed_hosts`.

The rationale for both gates is in
[../design/web-gui.md](../design/web-gui.md).

## Using the GUI

The GUI is organized into tabs.

### Dashboard

Read-only overview: software/bitstream versions, health and LED state,
cards, ports, SFP modules, and host-plane TAPs. Shows aggregate
counters plus a per-flow statistics table with health badges, an
error-event timeline, sparklines (rx bps / latency), and a latency
histogram with a multi-flow overlay and a log-scale toggle.

### Flows

An expandable per-flow editor with sections for `l2`, `ipv4` | `ipv6`,
`udp` | `tcp`, `traffic`, `measurements`, `match`, `modifiers`, and
`encap`. Edits are staged in a working copy:

- **Apply edit** commits your changes to the in-memory config and
  updates the raw-YAML preview.
- **Write to card** programs the committed config into the daemon
  (`config.load`). Client-side validation blocks a bad write before it
  reaches the daemon.

A **👁 Preview frame** button with a **seq** box decodes and hex-dumps
the exact frame the generator would emit; it updates live as you change
`seq`, so you can watch per-packet modifiers take effect. **Copy YAML +
CLI** copies both the config YAML and the equivalent `pktwyrm`
commands.

### Forwards

Store-and-forward rules, with the same staged-edit UX (**Apply edit** /
**Write to card**) as the Flows tab.

### Control

Whole-tester and per-flow orchestration: test arm / start / stop,
per-flow start / stop, and stats clear — each with a copy-as-CLI
button. Remember the **explicit-start model**: the daemon programs
flows idle, and nothing transmits until you press Start.

### Environment

View and edit the environment config (`config.get_raw` /
`config.save`). The `system.secret` is redacted in the view.

## Remote CLI

The same gateway also fronts the CLI:

```sh
pktwyrm --host HOST[:PORT] ...
```

routes `pktwyrm` through the gateway over HTTPS instead of the local
Unix socket — handy for driving a remote tester from your workstation
with the same commands you use locally.

## See also

- [installation.md](installation.md) — installing the daemon and gateway.
- [running-tests.md](running-tests.md) — building and running traffic tests.
- [monitoring.md](monitoring.md) — stats, histograms, and Prometheus.
- [../design/web-gui.md](../design/web-gui.md) — gateway architecture and security model.
