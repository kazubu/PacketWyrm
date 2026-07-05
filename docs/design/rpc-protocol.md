# JSON-RPC protocol

`packetwyrmd` listens on a Unix domain socket (default
`/run/packetwyrm/packetwyrmd.sock`, override via
`system.control_socket` in YAML). `pktwyrm` and any other client
speak a tiny request/response protocol over it.

## Wire format

Every message is a 4-byte big-endian length prefix followed by a
UTF-8 JSON body. One request per connection; the daemon sends one
response frame then closes. Max frame size is `PW_IPC_FRAME_MAX`
(64 KB today).

```
+---------+---------+---------+---------+--- ... ---+
|  len[31:24] | len[23:16] | len[15:8] | len[7:0] | JSON body |
+---------+---------+---------+---------+--- ... ---+
```

## Request envelope

```json
{ "rpc": "<method>", ...method-specific fields... }
```

## Methods

### `version`

```json
{ "rpc": "version" }
```
&rarr;
```json
{ "version": "0.1.0" }
```

### `cards`

```json
{ "rpc": "cards" }
```
&rarr;
```json
{ "cards": [ { "id": 0, "name": "card0", "pci": "0000:03:00.0",
              "backend": "fake" | "bar" | "absent", "open": true,
              "device_id": "0xa502beef", "fpga_version": 196608,
              "build_id": "0x6a4526ea", "git_hash": "0xadb9327a",
              "err_sticky": false, "activity": true,
              "temp_c": 54.3, "vccint_v": 0.85, "vccaux_v": 1.80 } ] }
```

FPGA identity (`device_id`/`fpga_version`/`build_id`/`git_hash`) comes from the
card. `err_sticky` is the live front-panel-LED bit (GLOBAL_STATUS[3] — latches on
any lost/decode/FCS error since the last `stats.clear`); `activity` is recent
traffic. `temp_c`/`vccint_v`/`vccaux_v` are the on-chip SYSMON readings. The
SYSMON + err_sticky fields are present only when the bitstream exposes them
(older images omit `temp_c` and report `err_sticky:false`).

### `ports`

```json
{ "rpc": "ports" }
```
&rarr; `{ "ports": [ { "name": "p0", "card_id": 0, "local_port": 0,
                       "global_port": 0 } ] }`

### `flows`

`{ "rpc": "flows" }` &rarr; `{ "flows": [ { "id", "name",
"tx_global_port", "rx_global_port", "tx_card_id", "rx_card_id",
"latency_valid", "latency_method" } ] }`

`latency_valid` is now `true` for **both** same-card and cross-card flows
(cross-card is HW-corrected, see `flow.stats`); `latency_method` is
`"same-card"` or `"gpio-corrected"` so a client can tell them apart. (Clients
should key latency-UI off `latency_valid` being true, not off the flow being
same-card.)

### `stats`

Card-level counters from the host packet plane.

```json
{ "rpc": "stats" }                  // all cards
{ "rpc": "stats", "card": 0 }       // one card
```
&rarr;
```json
{
  "stats": [
    {
      "card_id": 0, "open": true, "backend": "fake",
      "punt_to_tap_ok": 0, "punt_to_tap_dropped": 0,
      "tap_to_fpga_ok": 0, "tap_to_fpga_dropped": 0,
      "punt_unknown_lif": 0
    }
  ]
}
```

### `ports.stats`

Per-port wire counters from the MAC (`{ "rpc": "ports.stats" }`) &rarr;
`{ "fpga_ts_lo", "fpga_ts_hi", "ports": [ { "card_id", "local_port",
"global_port", "rx_frames", "rx_bytes", "tx_frames", "tx_bytes",
"rx_fcs_error", "drops", "rx_unmatched", "last_unmatched": { "ctx_raw",
"is_test", "is_ipv4", "is_ipv6", "hit", "action", "is_arp", "ethertype",
"l3_proto", "flow_id" }, "link_up_count", "block_lock_loss" } ] }`.
`drops` = **real drops only** (store-and-forward forward-buffer overflow).
`rx_unmatched` counts frames that were received (and counted in `rx_frames`) but
matched no classifier rule — informational, NOT a drop and NOT an error (e.g. the
host TAP's own IPv6 ND/MLD looped back). `last_unmatched` decodes the most recent
unmatched frame's identity so a rare miss can be attributed (real test-frame miss
= `is_test` + a known `flow_id`; stray/garbage frame = not).
This is authoritative per-port traffic (all frames, not just test flows, and
`rx_frames` counts unmatched frames too). A client derives per-port **pps/bps**
from the counter deltas divided by the `fpga_ts` delta (6.4 ns/tick — jitter-free
vs. wall-clock). `rx_fcs_error` and `drops` (real SAF-overflow drops) are the two
**per-port inputs to the front-panel LED `err_sticky`** — together with per-flow
`lost` (from `flow.stats`) they are the complete set of things that latch the
LED, so a red LED can always be attributed to a counter. `rx_unmatched` is
deliberately excluded and never lights the LED. Present only on backends with
per-port counters.

### `tap.stats`

Per-logical-interface **host-plane TAP** status + statistics (`{ "rpc":
"tap.stats" }`) &rarr; `{ "taps": [ { "name", "logical_if_id", "mac",
"global_port", "vlan", "mtu", "admin_up", "oper_up", "addrs": [ ... ],
"kernel": { "rx_packets", "rx_bytes", "rx_dropped", "tx_packets", "tx_bytes",
"tx_dropped" }, "bridge": { "to_tap_ok", "to_tap_dropped", "from_tap_ok",
"from_tap_dropped" } } ] }`. One entry per TAP netdev the daemon created (one
per logical interface). `name` is the actual kernel netdev name (e.g.
`tap-pw-p0-v100`); `admin_up`/`oper_up` are `IFF_UP`/`IFF_RUNNING`; `addrs` are
the host-assigned IP addresses (incl. the auto link-local IPv6 that generates
the ND/MLD traffic seen as per-port `rx_unmatched`). `kernel.*` are the Linux
netdev counters (host's point of view); `bridge.*` are the PacketWyrm host-plane
mover counters — `to_tap` = FPGA punt written to the TAP, `from_tap` = read from
the TAP and injected to the FPGA. SW-only (no FPGA access); present when the
daemon has host-plane TAPs (requires `CAP_NET_ADMIN` to have created them).
Surfaced by the GUI **Host-plane TAPs** dashboard panel and `pktwyrm tap`.

### `flow.stats`

Per-flow counters from the FPGA test-RX checker. Triggers a
fresh snapshot on each open card before reading. The response also carries
`fpga_ts_lo`/`fpga_ts_hi` (the FPGA free-running timestamp at snapshot, 6.4
ns/tick) so a client can compute exact per-flow frame/byte rates as
Δcounter / Δticks rather than relying on host poll timing.

```json
{ "rpc": "flow.stats" }                  // all flows
{ "rpc": "flow.stats", "id": 1 }         // one flow
```
&rarr;
```json
{
  "flows": [
    {
      "id": 1,
      "tx_card_id": 0, "rx_card_id": 0,
      "tx_frames": 0, "tx_bytes": 0,
      "rx_frames": 0, "rx_bytes": 0,
      "lost": 0, "duplicate": 0, "out_of_order": 0,
      "seq_gap": 0, "expected_seq": 0,
      "latency_valid": true,
      "min_latency": 0, "max_latency": 0,
      "avg_latency": 0, "sample_count": 0,
      "jitter_min": 0, "jitter_max": 0, "jitter_avg": 0
    }
  ]
}
```

Cross-card flows are supported via the J5 GPIO time-sync, **corrected in
hardware per sample, per flow**: the daemon servo writes each cross-card flow's
inter-card counter offset to its slot in the per-flow correction window
(`0x0180 + slot*8`, slot = the RX `local_flow_id`) every `-S` ms (default 10 ms;
1 ms in precision runs), and the RX checker computes `lat = (rx_wire_ts +
corr[slot]) - tx_ts`. So `min_latency`/`max_latency`/`avg_latency` here already
hold the true one-way latency -- no read-time correction, and `avg_latency` is
valid (the 64-bit `sum_latency` accumulates the now-small corrected value, so it
no longer overflows). Because correction is per flow, one RX card can mix
same-card and cross-card flows and take cross-card traffic from multiple TX
cards. Cross-card flows return `latency_valid: true`, `latency_method:
"gpio-corrected"`, and `offset_ticks` (the live servo offset, informational).
Same-card flows report `latency_method: "same-card"` and run with their slot's
`corr = 0` (identical to before). `latency_valid` is also gated on the counter
read succeeding (`read_ok`). `jitter_*`
is valid in both cases. Requires the cards' J5 headers to be wired. Because the
correction is tracked per sample, min/max/avg no longer smear over a long
accumulation (the earlier read-time single-offset scheme did, under the ~ppm
clock skew) -- a `stats.clear` short-window workaround is no longer needed.

### `flow.hist`

Per-flow power-of-two latency histogram.

```json
{ "rpc": "flow.hist", "id": 1 }
```
&rarr;
```json
{
  "id": 1,
  "n_buckets": 64,
  "buckets": [ 0, 0, 12, 105, ... ]
}
```

Cross-card histograms are now supported too: the hardware bins the per-sample
latency *after* the `lat_correction` offset (kept current by the daemon servo),
so the buckets hold the true one-way latency, exactly like same-card. (This was
previously punted, when the HW binned the raw uncorrected latency.)

### `sfp.info`

Per-SFP module identifier + DOM, read over each card's I2C management bus.

```json
{ "rpc": "sfp.info" }                        // all open cards, both ports
{ "rpc": "sfp.info", "card": 0 }             // one card
{ "rpc": "sfp.info", "card": 0, "port": 1 }  // one port
```
&rarr;
```json
{ "sfp": [
  { "card_id": 0, "port": 0, "present": true,
    "identifier": 3, "connector": 7,
    "vendor": "FINISAR CORP.", "part": "FTLX1471D3BCL", "revision": "A",
    "serial": "UJ702MB", "date_code": "100816", "br_nominal_mbaud": 10300,
    "dom_supported": true, "dom_external_cal": false, "dom_valid": true,
    "temp_c": 54.2, "vcc_v": 3.29, "tx_bias_ma": 46.7,
    "tx_power_mw": 0.702, "rx_power_mw": 0.213 } ] }
```

`present:false` (with `error` for an I2C fault) marks an empty cage. DOM fields
appear only when `dom_valid` (internally-calibrated DDM module); a passive DAC or
externally-calibrated module has `dom_supported`/`dom_external_cal` set but no
DOM values. `pktwyrm sfp [--card N] [--port P] [--json]` pretty-prints it (TX/RX
in dBm). Requires the `REG_SFP_I2C` bitstream on the card.

### `flow.start` / `flow.stop`

Toggle the TX-side enable bit of a flow.

```json
{ "rpc": "flow.start", "id": 1 }
{ "rpc": "flow.stop",  "id": 1 }
```
&rarr;
```json
{ "id": 1, "enable": true, "status": "ok" }
{ "id": 1, "enable": false, "status": "ok" }
```

`status` is the human-readable form of the underlying
`pw_status` (e.g. `"ok"`, `"invalid argument"`,
`"not implemented"`).

### `test.arm` / `test.start` / `test.stop`

Whole-tester orchestration. `arm` re-pushes the compiled
program to every open backend (idempotent resync). `start` and
`stop` toggle the enable bit of every flow.

> **Not hitless.** `test.arm` (and `config.load` below) re-run
> `program_backends`, which pulses the data-plane soft reset
> (`PWFPGA_REG_DP_RESET`) before rewriting the tables — deliberately, so
> reprogramming over a running data plane can't wedge it. That reset briefly
> quiesces the generators / SAF / arbiters, so any frames in flight at that
> instant (including slow-path punt / inject / forward traffic) are dropped, and
> the card worker's DMA slow path is NOT paused around it. Measured: rapid
> `config.load`/`test.arm` while a control-plane ping crossed the DUT showed
> ~23 % transient loss during the reloads, recovering cleanly afterward (no
> wedge, no error latch). Treat arm/reload as a disruptive operation — don't
> expect a live control plane to survive it without a brief hiccup.

```json
{ "rpc": "test.start" }
```
&rarr;
```json
{ "action": "test.start", "changed": 2, "failed": 0 }
```

### `config.load`

Live reload: parse, validate, and compile a YAML body, then swap
it into the running daemon. The `yaml` body is normally a **test
config** (flows/forwards only) which is merged onto the daemon's
running environment (cards / logical_interfaces stay). A full
combined config (with `cards`) is also accepted for back-compat.

```json
{ "rpc": "config.load", "yaml": "flows:\n  - id: 1\n..." }
```
&rarr; on success:
```json
{ "ok": true, "n_flows": 1, "n_classifier_rows": 4 }
```

Constraints:

- A test-only body (no `cards`) is merged onto the running
  environment. A combined body (with `cards`) **must** have the
  same cards and logical interfaces (by id) as the running config;
  topology changes require a full daemon restart (live unplugging a
  TAP / backend mid-traffic isn't safe) and are rejected with
  `{"error": "topology change ..."}`.
- Old flows are stopped (enable bit cleared) before the new
  program is pushed. There is a brief window with no flows
  enabled; accept it as the cost of correctness for V1.
- Any failure before the swap (parse / validate / compile)
  leaves the previous program live; only the error response
  is returned.

`pktwyrm load <config.yaml> --socket PATH` is the user-facing
front-end: it compiles offline first (for clean syntax errors),
then ships the YAML body to the daemon.

### `config.get_raw`

Return the raw text of the environment config file (the daemon's `-e`
path) so a GUI can edit it. The `secret:` value is **structurally redacted**
to the sentinel `"***"` (only the `secret:` key line is rewritten — not a
blanket value replacement, so a secret that happens to equal a card/interface
name is never clobbered). `config.save` recognizes that sentinel and preserves
the existing secret, so a client can safely round-trip get_raw → edit → save
without needing to know the secret. (Inline `system: { secret: ... }` flow
mappings are not matched by the line scan; use block form.)

```json
{ "rpc": "config.get_raw" }
```
&rarr;
```json
{ "path": "/etc/packetwyrm/packetwyrm.yaml",
  "yaml": "system:\n  secret: \"***\"\n  ...",
  "secret_set": true }
```

### `config.get_test`

Return the active **test-config** YAML (flows / forwards) text so a GUI can
load and edit the running flows. The daemon stashes this text from the `-t`
file at startup and from each successful `config.load` (it otherwise keeps
only the parsed `pw_config`, not the source).

```json
{ "rpc": "config.get_test" }
```
&rarr;
```json
{ "yaml": "flows:\n  - id: 1\n  ...", "loaded": true,
  "flows": [ { "id":1, "tx":0, "rx":1, "l3":"ipv4", "l4":"udp", ...,
               "match": {...}, "mods": {...}, "encap": {...} } ],
  "forwards": [ { "ingress":0, "egress":1, ... } ] }
```

Returns two views of the running test config:
- `yaml` — the exact submitted text (lossless; empty and `loaded:false` when
  no test config was loaded via `-t` / `config.load` this session).
- `flows` / `forwards` — the running config serialized as structured JSON in
  the **GUI form-model shape** (including `match` / `mods` / `encap`,
  `frame_template` + `ethertype`, and `rate_mode`+`rate` preserving whether the
  flow used rate_bps or rate_pps so Load current → Apply round-trips), so the
  Flows tab's **Load current** can populate the point-and-click form, not just
  the raw editor. (`flows` may be non-empty even when `loaded:false` if flows
  came from a combined `-e` file.) IPv4 addresses are emitted dotted, IPv6
  compressed; IPv6 modifier masks as address literals; match IPv6 as prefix
  lengths. Rate round-trips exactly (bps or pps, via `rate_mode`+`rate`). The
  one form approximation is a **frame-length range** (`frame_len_min/max/step`):
  the form carries a single `frame_len`, so it shows the min and the `yaml` view
  is authoritative for the range. Backs the Flows tab's **Load current** button.

### `config.save`

Validate a full environment YAML (parse + validate) and, on success,
write it **atomically** (tmp + rename) to the daemon's `-e` path —
**only** that path, never a client-supplied one.

```json
{ "rpc": "config.save", "yaml": "system:\n  ...\ncards:\n  ..." }
```
&rarr;
```json
{ "ok": true, "path": "/etc/packetwyrm/packetwyrm.yaml",
  "restart_required": true }
```

`restart_required` is `true` whenever the saved file differs from what the
daemon is currently running — config.save is a file write, not a live reload,
so **any** change (secret, system, logical_ifs, cards) needs a restart to take
effect (a no-op save returns `false`). `topology_change` is a separate bool:
`true` when cards / logical_interfaces differ (that additionally can never be a
live swap, per config.load's constraint). A parse or
validate failure returns `{"error": "..."}` and writes nothing. If the
submitted `secret:` is the redaction sentinel `"***"` (the get_raw view saved
back unchanged), the daemon **rewrites it to the running secret** before
writing — a thoughtless Save can't lock the operator out — and rejects if the
placeholder can't be resolved. The file is written atomically (tmp+rename)
preserving the existing mode/owner (a 0600 secret file stays 0600, not
umask-widened). Security: a root daemon writes its own env file over an
authenticated (secret + TLS via the gateway) RPC; the write target is fixed and
the YAML is fully validated first. Used by the Web GUI's Environment tab.

The gateway also serves `GET /proxyd/version` → `{ "version": "..." }` for its
own build version (the daemon's is the `version` RPC; per-card FPGA versions are
in `cards`).

## Web GUI gateway + remote transport

Browsers and remote CLIs do not speak the length-prefixed socket
protocol directly. `packetwyrm-proxyd` terminates HTTPS and relays
`POST /api/rpc` bodies verbatim onto this control socket, so **the JSON
request/response schema above is identical** whether it arrives over the
Unix socket, `pktwyrm --host` (HTTPS), or the browser. The gateway is a
stateless relay and the daemon remains the sole auth authority. See
`web-gui.md`.

## Access control (secret)

When the environment config sets `system.secret`, every request must carry a
matching `"secret"` string field; the daemon compares it (constant-time) and
otherwise replies `{ "error": "unauthorized" }`. A client obtains the secret in
this precedence: `pktwyrm --secret S`  >  `$PACKETWYRM_SECRET`  >  the `secret`
key of the environment config (`--env PATH`, default
`/etc/packetwyrm/packetwyrm.yaml`). So **read permission on the environment
config file is the access gate** — a process that can't read it can't obtain the
secret and is rejected. If no secret is configured, auth is disabled and the
socket file permissions are the only ACL: in production the daemon creates it
`0660 root:packetwyrm` (root, or a member of the `packetwyrm` group such as the
proxyd gateway), while dev/CI (`-F`) uses `0666`. The `secret` field is injected
by `pktwyrm` automatically; a raw `pktwyrm rpc` also picks it up.

## Errors

Any unhandled situation responds with:

```json
{ "error": "<short message>" }
```

`pktwyrm rpc <method>` prints the raw JSON. The pretty-printing
subcommands (`pktwyrm stats`, `pktwyrm hist latency`) parse it
and surface the error in a human-friendly form.

## Prometheus exposition

Independent of the JSON RPC, `packetwyrmd -p PORT` exposes a
plain HTTP `/metrics` endpoint serving the standard Prometheus
text format. The metrics map 1:1 onto the host packet plane
counters; see `packetwyrmd --help` for the latest list.
