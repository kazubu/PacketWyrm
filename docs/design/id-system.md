# ID system

PacketWyrm uses a deliberately multi-card ID system from day one. Even a
single-card deployment programs the FPGA through the same `card_id` /
`global_port_id` / `local_port_id` chain that a four-card deployment
uses, so no design decision quietly assumes "only one card".

The unrenounceable rule: **the FPGA RTL only ever sees local IDs;
everything global is owned by `packetwyrmd`.**

## ID types

### `card_id` (u16)

Daemon-assigned, stable for the lifetime of a daemon process. Order is
determined by PCIe BDF sort (deterministic) and is logged at startup.
Loss of a card preserves the slot until reload; `card_id` does not get
re-shuffled when card K disappears.

```
card0 -> 0000:03:00.0
card1 -> 0000:04:00.0
card2 -> 0000:05:00.0
```

### `local_port_id` (u8)

Physical SFP+ port within a single AS02MC04. Always `0` or `1`. This is
the only port identifier ever written into FPGA CSRs / flow entries /
classifier entries.

### `global_port_id` (u16)

Tester-wide unique port name. Configured in YAML; daemon validates that
each `(card_id, local_port_id)` maps to exactly one `global_port_id`
and vice versa.

```
card0 local 0 -> p0
card0 local 1 -> p1
card1 local 0 -> p2
card1 local 1 -> p3
```

The text form is `p<global_port_id>`. There is intentionally no
`as02-*` form anywhere in user-visible output.

### `global_flow_id` (u32)

User-facing flow identifier. Unique tester-wide. Referenced by CLI,
YAML, stats output. Must not collide.

### `local_flow_id` (u32)

Per-card flow table index. Assigned by the daemon's flow compiler
during programming. A single `global_flow_id` may produce up to two
`local_flow_id` allocations &mdash; one on the TX card, one on the RX
card &mdash; for a cross-card flow.

### `logical_if_id` (u32)

Tester-wide logical interface ID used to bind:

- a TAP / netdev (`tap-pw-p<gport>-v<vlan>`),
- a classifier `PUNT_TO_HOST` action,
- and a Linux-injected slow-path egress descriptor.

`logical_if_id` is also unique tester-wide. The FPGA stores it as an
opaque tag inside punt descriptors and classifier hits; only Linux
interprets it.

## Reference structures

These are also defined as C types in `sw/libpacketwyrm/include/packetwyrm/ids.h`.

```c
struct pwfpga_port_ref {
    uint16_t card_id;
    uint8_t  local_port_id;
    uint16_t global_port_id;
};

struct pwfpga_logical_if {
    uint32_t logical_if_id;
    uint16_t global_port_id;
    uint16_t card_id;
    uint8_t  local_port_id;
    uint16_t vlan_id;
    char     if_name[32];   /* "tap-pw-p0-v100" */
};
```

## Allocation rules

- `card_id`: assigned at daemon startup in PCIe BDF order. Stable for
  the process lifetime.
- `global_port_id`: assigned by YAML config; daemon refuses to start if
  duplicates or holes inconsistent with declared cards exist.
- `global_flow_id`: declared in YAML, must be globally unique.
- `local_flow_id`: assigned by the flow compiler; not stable across
  config reloads.
- `logical_if_id`: declared in YAML, must be globally unique.

## Validation

`packetwyrmd` rejects any configuration that contains:

- duplicate `card_id`,
- duplicate `global_port_id`,
- a `global_port_id` that resolves to no physical card,
- duplicate `(card_id, local_port_id)`,
- duplicate `global_flow_id`,
- duplicate `logical_if_id`,
- a flow whose `tx_global_port` or `rx_global_port` is unknown,
- a flow whose `logical_if_id` is not declared,
- a logical interface whose `global_port_id` is not declared,
- a cross-card flow that requests `latency: true` or `jitter: true`
  (until a clock-sync phase ships).

The last rule is intentional: silently producing nonsensical numbers is
worse than refusing the configuration.
