# Web GUI + remote access (`packetwyrm-proxyd`)

The Web GUI and remote CLI access are provided by a **separate gateway
process**, `packetwyrm-proxyd`, not by `packetwyrmd` itself. This keeps
all TLS / HTTP parsing and the network-facing attack surface out of the
hardware-owning daemon, and — crucially — means the daemon's
single-threaded control loop (which interleaves `config.load` and the
cross-card latency servo) is never blocked by a slow TLS handshake or a
stalled HTTP client.

```
[browser]        --HTTPS--┐
                          ├─► [packetwyrm-proxyd] ──Unix socket──► [packetwyrmd]
[pktwyrm --host] --HTTPS--┘   TLS terminate           (4B len + JSON)   (auth authority)
                              static GUI + /api/rpc
```

## What the gateway does

`packetwyrm-proxyd` (`sw/packetwyrm-proxyd/`) is a **stateless relay**:

- `GET /` (and `/index.html`) → serves the embedded single-page GUI
  (`assets/index.html`, compiled into the binary via `xxd -i`).
- `POST /api/rpc` → the request body **is** a daemon control-socket
  request (`{"rpc":...}` JSON, including any `"secret"`). The gateway
  forwards it verbatim to `packetwyrmd` over the Unix socket
  (`pw_ipc_connect` / `pw_ipc_write_frame` / `pw_ipc_read_frame` from
  `libpacketwyrm`) and returns the daemon's JSON reply. The gateway does
  **not** parse or understand the RPC.

Because it holds no shared state with the daemon and each connection is
handled on its own thread (`thread-per-connection`, capped at 32), there
are no locks and no coupling to the daemon's control/servo timing.

## Options

```
packetwyrm-proxyd [--listen ADDR:PORT] [--socket DAEMON_SOCK]
                  [--tls-cert FILE --tls-key FILE] [--no-tls]
                  [--insecure-no-auth]
```

- `--listen` — default `0.0.0.0:8443`.
- `--socket` — daemon control socket (default
  `/var/run/packetwyrm/packetwyrmd.sock`).
- `--tls-cert` / `--tls-key` — a real PEM certificate + key. If omitted,
  the gateway generates an **in-memory self-signed EC (P-256)**
  certificate at startup and prints its SHA-256 fingerprint (browsers
  will warn; verify against the printed fingerprint).
- `--no-tls` — serve plain HTTP (for localhost / behind an SSH tunnel).
- `--insecure-no-auth` — see below.

## Security model

- **Authentication is unchanged and lives entirely in the daemon.** If
  the environment config sets `system.secret`, `packetwyrmd` requires a
  matching `"secret"` on every request (constant-time compare). The
  gateway forwards the client-supplied secret verbatim; it never sees or
  stores the secret itself. See `rpc-protocol.md` → *Access control*.
- **TLS terminates at the gateway.** The secret and all data are
  encrypted over the network. The gateway↔daemon hop is a local Unix
  socket (trusted, same host).
- **Runs unprivileged.** The gateway only needs to reach the daemon's
  `0666` control socket, so the shipped systemd unit
  (`packaging/packetwyrm-proxyd.service`) runs it as the unprivileged
  `packetwyrm` user — the network-facing process owns no hardware.
- **No-auth safeguard.** At startup the gateway probes the daemon with an
  unauthenticated `version`. If the daemon has **no** secret configured
  and the listen address is **not** loopback, the gateway *refuses to
  start* — otherwise anyone reaching the port would have full control.
  Override with `--insecure-no-auth` (or bind `127.0.0.1`, or set a
  secret).

## Remote CLI: `pktwyrm --host`

`pktwyrm --host HOST[:PORT]` (default port 8443) routes every RPC through
the gateway over HTTPS (`POST /api/rpc`) instead of the local Unix
socket. Secret resolution is unchanged (`--secret` > `$PACKETWYRM_SECRET`
> `--env` file). The gateway's cert is self-signed by default, so the
client does not verify it (a one-time notice is printed); certificate
verification (`--ca`) is a future addition.

## The GUI

A single self-contained `index.html` (inline CSS/JS, no external/CDN
dependencies). Tabs:

- **Dashboard** — polls `cards` / `ports` / `sfp.info` / `flow.stats`
  every ~1.5 s; per-flow latency histogram via `flow.hist`.
- **Flows** — point-and-click editor for the common flow schema
  (ports / L2 / L3 v4|v6 / L4 udp|tcp / traffic / measurements /
  classify / background) with a live generated-YAML preview; **Apply**
  ships it via `config.load`. A raw-YAML escape hatch covers features the
  form omits (encap, modifiers, match masks). The YAML the form emits is
  exactly what `packetwyrmd` parses (see `yaml-schema.md`).
- **Forwards** — form editor for store-and-forward rules → `config.load`.
- **Control** — `test.arm` / `test.start` / `test.stop`, `stats.clear`,
  per-flow `flow.start` / `flow.stop`.
- **Environment** — `config.get_raw` → edit → `config.save` (see
  `rpc-protocol.md`); a banner warns when a topology change requires a
  daemon restart. The `secret` value is shown redacted.

The secret is entered once in the header and kept in `localStorage`.

## Build / deploy

- `make -C sw proxyd` builds `build/packetwyrm-proxyd` (links OpenSSL +
  `libpacketwyrm`; the GUI is embedded at build time). `make install`
  installs it to `$(SBINDIR)` with its systemd unit.
- CI (`.github/workflows/ci.yml`) installs `libssl-dev` + `xxd`, builds
  it as part of `make`, and exercises the relay in `make e2e`
  (`tests/integration/e2e_proxyd.sh`).
