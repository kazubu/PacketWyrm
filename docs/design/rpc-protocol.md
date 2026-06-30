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
hardware per sample**: the daemon servo writes the inter-card counter offset to
each RX card's `lat_correction` CSR (`0x0144/0x0148`) ~10×/s, and the RX checker
computes `lat = (rx_wire_ts + offset) - tx_ts`. So `min_latency`/`max_latency`/
`avg_latency` here already hold the true one-way latency -- no read-time
correction, and `avg_latency` is valid (the 64-bit `sum_latency` accumulates the
now-small corrected value, so it no longer overflows). Cross-card flows return
`latency_valid: true`, `latency_method: "gpio-corrected"`, and `offset_ticks`
(the live servo offset, informational). Same-card flows report `latency_method:
"same-card"` and run with `lat_correction = 0` (identical to before). `jitter_*`
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
it into the running daemon. The request must carry the full YAML
configuration as a string (UTF-8).

```json
{ "rpc": "config.load", "yaml": "system:\n  name: pw\n..." }
```
&rarr; on success:
```json
{ "ok": true, "n_flows": 1, "n_classifier_rows": 4 }
```

Constraints:

- The new config **must** have the same cards and logical
  interfaces (by id) as the running config. Topology changes
  require a full daemon restart, because live unplugging a
  TAP / backend mid-traffic isn't safe. Topology mismatch is
  rejected with `{"error": "topology change ..."}`.
- Old flows are stopped (enable bit cleared) before the new
  program is pushed. There is a brief window with no flows
  enabled; accept it as the cost of correctness for V1.
- Any failure before the swap (parse / validate / compile)
  leaves the previous program live; only the error response
  is returned.

`pktwyrm load <config.yaml> --socket PATH` is the user-facing
front-end: it compiles offline first (for clean syntax errors),
then ships the YAML body to the daemon.

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
