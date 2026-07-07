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
  `/run/packetwyrm/packetwyrmd.sock`).
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
  control socket, so the shipped systemd unit
  (`packaging/packetwyrm-proxyd.service`) runs it as the unprivileged
  `packetwyrm` user/group — the network-facing process owns no hardware.
  In production the daemon creates the socket `0660 root:packetwyrm` (not
  world-writable), so the gateway reaches it via its `packetwyrm` group
  membership; dev/CI (`-F`) uses `0666`. The `packetwyrm` user+group are
  created by `packaging/packetwyrm.sysusers`.
- **No-auth safeguard.** At startup the gateway probes the daemon with an
  unauthenticated `version`. If the daemon has **no** secret configured
  and the listen address is **not** loopback, the gateway *refuses to
  start* — otherwise anyone reaching the port would have full control.
  Override with `--insecure-no-auth` (or bind `127.0.0.1`, or set a
  secret). Non-loopback binds also **re-confirm** the daemon still
  requires a secret at most every 60 s (lazy, on request arrival) and
  fail closed with 403 — a daemon restarted without its secret behind a
  long-running public gateway is caught, not silently exposed.
- **CSRF / DNS-rebinding defence on `POST /api/rpc`.** Two independent
  gates, both required:
  1. the custom header `X-PW-Request: 1` — genuinely cross-origin pages
     trigger a CORS preflight for it, and the gateway never answers
     `OPTIONS`, so browser-borne cross-site POSTs die at the preflight;
  2. an allow-listed `Host` header (`localhost`, `127.0.0.1`, `[::1]`,
     the `--listen` address, or names given via
     `--allowed-host NAME[,NAME...]`) — this is the half that stops DNS
     rebinding, where the attacker's page is *same-origin* by the
     browser's lights (custom headers flow freely) but carries the
     attacker's hostname in `Host`.
  Violations get `403` with a JSON error. The GUI's `rpc()` helper and
  `pktwyrm --host` both send the header; plain `curl` callers must add
  `-H 'X-PW-Request: 1'`. Without these gates, the *sanctioned*
  secretless-loopback deployment was drivable by any web page in a local
  browser (`config.save` writes `/etc/packetwyrm/` as root).
- **Whole-request deadline.** Each request (headers + body) must
  complete within 30 s (`408` otherwise). The per-read socket timeout
  alone let a Slowloris client (1 byte every ~14 s) pin all 32 workers
  indefinitely.

## Remote CLI: `pktwyrm --host`

`pktwyrm --host HOST[:PORT]` (default port 8443) routes every RPC through
the gateway over HTTPS (`POST /api/rpc`) instead of the local Unix
socket. Secret resolution is unchanged (`--secret` > `$PACKETWYRM_SECRET`
> `--env` file). The gateway's cert is self-signed by default, so the
client does not verify it (a one-time notice is printed); certificate
verification (`--ca` / fingerprint pinning) is a future addition.

> **Security tradeoff (accepted, by design for the lab).** Because the
> client does NOT verify the gateway certificate, the encrypted channel
> is confidential but **not authenticated** — a man-in-the-middle on the
> path could present its own cert and capture the `system.secret` (and
> thus gain control). This is an accepted tradeoff for the lab use case
> (`pktwyrm --host` over a **trusted network / SSH tunnel / VPN**). Do
> NOT expose the gateway on an untrusted network without an authenticated
> transport in front of it (e.g. an SSH tunnel, a VPN, or a reverse proxy
> doing mTLS). Certificate/fingerprint pinning in `pktwyrm` would remove
> this tradeoff and is tracked as a future addition.

## The GUI

A single self-contained `index.html` (inline CSS/JS, no external/CDN
dependencies). Tabs:

- **Dashboard** — polls every ~1.5 s: a **Versions** panel (packetwyrmd via
  `version`, packetwyrm-proxyd via `GET /proxyd/version`, per-card FPGA
  device/version/build/git + SYSMON die-temp/VCCINT/VCCAUX from `cards`); a
  **Health / LED** panel per card showing the FPGA's real `err_sticky` LED bit
  (`cards.err_sticky` when the bitstream exposes it, else inferred from live
  counters), with the causing counters incl. per-port FCS from `ports.stats`;
  a **Ports** table with per-port pps/bps (`ports.stats` deltas over the FPGA
  timestamp) + `sfp.info` (numbers capped to 3 decimals);
  **Aggregate counters** (total / per rx-card / per rx-port, with frames/s
  rates); **Flow statistics** with Started/Stopped state, tx/rx frames + pps + rx bps,
  and error counters (lost/dup/reorder) highlighted red when non-zero; and a
  per-flow **latency histogram** (`flow.hist`) with time-unit bucket labels
  (ns/µs/ms, from the 6.4 ns/tick clock).
- **Flows** — point-and-click editor for the full flow schema:
  ports / L2 (incl. `ethertype`) / L3 v4|v6 / L4 udp|tcp / traffic (incl.
  `frame_template` test|raw|ip|eth) / measurements / classify /
  background, plus collapsible advanced sections for **match** (classifier
  masks), **modifiers** (per-field static/increment/random + mask, incl.
  128-bit IPv6 literal masks), and **encap** (IPIP / GRE / EtherIP outer
  v4|v6 + EtherIP inner L2 + `rx_expect`). A live generated-YAML preview
  shows exactly what **Apply** ships via `config.load`. **Load current**
  pulls the running test config (`config.get_test`) into **both** the form
  (from the structured `flows`/`forwards` JSON — match/modifiers/encap
  included) **and** the raw-YAML editor (the exact text, for lossless bulk
  edits via **Apply raw YAML**). The YAML the form emits is exactly what
  `packetwyrmd` parses (see `yaml-schema.md`).
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
