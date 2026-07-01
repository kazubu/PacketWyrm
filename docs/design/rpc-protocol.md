# JSON-RPC protocol

`packetwyrmd` listens on a Unix domain socket (default
`/var/run/packetwyrm/packetwyrmd.sock`, override via
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
              "backend": "fake" | "bar" | "absent",
              "open": true } ] }
```

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

### `flow.stats`

Per-flow counters from the FPGA test-RX checker. Triggers a
fresh snapshot on each open card before reading.

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

## Access control (secret)

When the environment config sets `system.secret`, every request must carry a
matching `"secret"` string field; the daemon compares it (constant-time) and
otherwise replies `{ "error": "unauthorized" }`. A client obtains the secret in
this precedence: `pktwyrm --secret S`  >  `$PACKETWYRM_SECRET`  >  the `secret`
key of the environment config (`--env PATH`, default
`/etc/packetwyrm/packetwyrm.yaml`). So **read permission on the environment
config file is the access gate** — a process that can't read it can't obtain the
secret and is rejected. If no secret is configured, auth is disabled (the socket
is otherwise open, mode 0666). The `secret` field is injected by `pktwyrm`
automatically; a raw `pktwyrm rpc` also picks it up.

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
