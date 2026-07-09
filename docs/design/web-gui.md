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

- `GET /<path>` → serves a static GUI asset by **exact lookup** in an embedded
  blob table. The whole `assets/` tree (`index.html` + `css/app.css` +
  `js/*.mjs` ES modules + any `vendor/` libs) is compiled into the binary at
  build time by `gen_assets.py` (replaces the old single-file `xxd -i`). `/`
  maps to `/index.html`; a query string is stripped before lookup; unknown
  paths 404. Because the match is exact against the in-binary table (no
  filesystem access), path traversal is structurally impossible. Every response
  carries a same-origin **Content-Security-Policy** (`default-src 'self';
  script-src 'self'; style-src 'self' 'unsafe-inline'; …`) and
  `X-Content-Type-Options: nosniff`. Adding an asset = drop it under `assets/`
  and rebuild.
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
packetwyrm-proxyd [-c|--config FILE] [--listen ADDR:PORT] [--socket DAEMON_SOCK]
                  [--tls-cert FILE --tls-key FILE] [--no-tls]
                  [--insecure-no-auth] [--allowed-host NAME[,NAME...]]
```

All options can be set in a **config file** (`--config FILE`; the packaged
systemd unit uses `/etc/packetwyrm/proxyd.yaml`), one `key: value` per line
(`#` comments allowed). Keys mirror the flags: `listen`, `socket`, `tls_cert`,
`tls_key`, `no_tls`, `insecure_no_auth`, `allowed_hosts`. A CLI flag overrides
the file, so operators edit the file and `systemctl restart packetwyrm-proxyd`
rather than editing a unit drop-in. Example:

```yaml
listen: "0.0.0.0:8443"
socket: "/run/packetwyrm/packetwyrmd.sock"
no_tls: false
insecure_no_auth: false
allowed_hosts: "gw.example.com,203.0.113.10"
```

- `--listen` — default `0.0.0.0:8443`; the shipped `proxyd.yaml` sets
  `127.0.0.1:8443`.
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

Self-contained, no external/CDN dependencies — all served same-origin by proxyd:
`index.html` is a thin shell that pulls `/css/app.css` and the ES-module app
under `/js/` (`main.mjs` → `dom` / `rpc` / `format` / `state` / `yaml` / `ui` /
`flows` / `forwards` / `control` / `dashboard` / `events` / `env`). No bundler (native ES
modules); libraries are vendored under `assets/vendor/` (currently **js-yaml**,
loaded as a classic `<script>` so `window.jsyaml` is ready before the module —
used for client-side YAML syntax validation with line numbers before Apply-raw /
Env Save). Shared UX widgets (toasts, a confirm modal, an async-button/pending
helper) and inline-SVG sparklines live in `js/ui.mjs` + `js/chart.mjs`.

UX niceties: destructive actions confirm via a modal and every RPC button shows a
pending state; a sticky status bar + anomaly highlighting + sparklines make the
dashboard scannable (rates are raw, deliberately not smoothed); the Flows raw-YAML
editor tracks manual edits so a form change can't silently clobber them (with a
"Regenerate from form" escape hatch), validates fields (MAC/port/range/hex) before
Apply, and inserts spaces on Tab. Accessibility/polish: an ARIA tablist
(tab/tabpanel with `aria-selected`), `:focus-visible` rings, `<th scope>` and
aria-labelled icon buttons; a persisted light/dark theme toggle (🌓 in the
header; light is opt-in via `<html data-theme="light">`); and a responsive
layout (header/nav wrap, cards scroll horizontally) so wide tables don't break
narrow screens. Tabs:

- **Dashboard** — a sticky **status bar** across all tabs (test running/stopped,
  aggregate tx/rx pps, total loss, health, max die-temp — chips go red/amber on
  loss/error/high-temp; health mirrors the Health panel), then panels polled
  ~1.5 s: **Versions** (packetwyrmd via `version`, packetwyrm-proxyd via
  `GET /proxyd/version`, per-card FPGA device/version/build/git + SYSMON
  die-temp/VCCINT/VCCAUX from `cards`); **Health / LED** per card (the FPGA's real
  `err_sticky` bit when the bitstream exposes it, else inferred from live
  counters, with the causing counters incl. per-port FCS from `ports.stats`);
  a **Ports** table with per-port pps/bps + an rx-pps sparkline (FCS/drops red
  when non-zero) + `sfp.info`; **Aggregate counters** (total / per rx-card /
  per rx-port, with tx/rx frames + pps + bps, thousands-separated, plus an
  aggregate rx-bps sparkline on the Total row); **Flow statistics** with a
  per-flow **health badge** (client-side, from poll-to-poll deltas: red =
  lost/dup/reorder increased since the last poll; yellow = `read_ok:false`, tx
  growing with no rx, or idle with previously-accumulated errors; green = rx
  flowing with no new errors; grey = **idle** — no tx/rx growth and no
  accumulated errors, so a programmed-but-not-started flow never reads as
  broken; a `running:false` field from the daemon, when present, forces idle;
  the tooltip explains the verdict), Started/Stopped state, tx/rx frames + pps
  + bps, an rx-bps sparkline and an avg-latency sparkline with a min-max band,
  and lost/dup/reorder highlighted red (lossy rows tinted); an **Events**
  timeline card (client-side ring buffer, last 200, newest first, Clear
  button): each poll diffs per-flow lost/dup/reorder/seq-gap and per-port
  FCS/drop counters and logs a timestamped entry per positive delta
  ("12:34:56 flow 3: +5 lost" — answers *when* a soak broke), plus every GUI
  test action (arm/start/stop/clear, per-flow start/stop); and a per-flow
  **latency histogram** (`flow.hist`) that auto-selects the first flow and
  live-refreshes, with time-unit bucket labels (ns/µs/ms), an **overlay of up
  to 4 flows** (compare checkboxes; grouped color-coded bars + legend) and a
  **lin/log toggle** for the count axis (log is essential when one bucket
  dominates). Rates are shown RAW (no smoothing) so momentary changes stay
  visible; sparkline history is ~120 polls, counter resets (arm/`stats.clear`)
  render as gaps rather than spikes, and each series' SVG node is cached and
  updated in place (no per-poll SVG re-creation).
- **Flows** — each flow is an expandable row (single-open accordion) whose editor
  opens inline, covering the full schema: ports / L2 (incl. `ethertype`) / L3
  v4|v6 / L4 udp|tcp / traffic (incl. `frame_template` test|raw|ip|eth; the rate
  field shows a live SI-unit conversion) / measurements / classify / background,
  plus collapsible advanced sections for **match** (classifier masks),
  **modifiers** (static/increment/random + mask, incl. 128-bit IPv6 literal
  masks), and **encap** (IPIP / GRE / EtherIP + `rx_expect`). Editing is **staged**
  in a per-flow working copy: **Apply edit** commits it into the config + the raw
  YAML preview (a "● modified" badge marks uncommitted edits; **Revert** discards
  them) — this does NOT touch the card. The top **Write to card** button programs
  the committed config onto the FPGA via `config.load` (it warns on uncommitted
  editor edits and won't silently discard hand-edited raw YAML). Client-side field
  validation (MAC/port/range/hex) blocks a write with a "fix these" list.
  **Load current** pulls the running config (`config.get_test`) into both the form
  and the raw-YAML editor; **Apply raw YAML** writes the raw text (js-yaml
  syntax-checks it first, with a line number); **Regenerate from form** rebuilds
  the YAML from the model; and the YAML can be **saved to / loaded from a local
  file**. **Copy YAML + CLI** puts the test-config YAML on the clipboard and
  shows the equivalent copyable command sequence (`pktwyrm load
  packetwyrm-flows.yaml && pktwyrm test arm && pktwyrm test start`, prefixed
  with `--host <gateway>` when the GUI isn't served from localhost). The YAML
  the form emits is exactly what `packetwyrmd` parses (see `yaml-schema.md`).
- **Forwards** — store-and-forward rules with the same expandable-accordion,
  staged-edit UX as Flows (Apply edit / Revert / "● modified" / Write to card),
  sharing the working-copy + raw-YAML state (`js/staging.mjs`) and the
  `writeToCard` path (which validates + warns across flows *and* forwards).
- **Control** — `test.arm` / `test.start` / `test.stop`, `stats.clear`,
  per-flow `flow.start` / `flow.stop`. Each orchestration button carries a
  small ⧉ copy-CLI affordance (aria-labelled) that copies the equivalent
  `pktwyrm test arm|start|stop` / `pktwyrm stats clear` command; every action
  performed here is also logged to the Dashboard's Events timeline.
- **Environment** — `config.get_raw` → edit → `config.save` (see
  `rpc-protocol.md`); a banner warns when a topology change requires a
  daemon restart. The `secret` value is shown redacted.

The secret is entered once in the header and kept in `sessionStorage`
(per-tab, cleared when the tab/browser closes; any legacy `localStorage`
copy is migrated away on load).

## Build / deploy

- `make -C sw proxyd` builds `build/packetwyrm-proxyd` (links OpenSSL +
  `libpacketwyrm`; the whole `assets/` tree is embedded at build time by
  `gen_assets.py`, which needs `python3`). `make install` installs it to
  `$(SBINDIR)` with its systemd unit.
- CI (`.github/workflows/ci.yml`) installs `libssl-dev` (+ `python3` for the
  asset generator), builds it as part of `make`, and exercises the relay +
  multi-file serving in `make e2e` (`tests/integration/e2e_proxyd.sh`).
