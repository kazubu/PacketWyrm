# PacketWyrm Grafana dashboard

`packetwyrm-dashboard.json` visualizes the metrics exported by the PacketWyrm
daemon's built-in Prometheus text exporter.

## 1. Enable the exporter

The daemon serves `/metrics` when started with `-p [ADDR:]PORT`. The packaged
systemd unit already passes `-p 9100`, bound to loopback (`127.0.0.1`) by
default:

```
ExecStart=/usr/bin/packetwyrmd -c /etc/packetwyrm/packetwyrm.yaml -s 5000 -p 9100
```

The exporter is **unauthenticated**. To scrape it from another host, change the
unit to `-p 0.0.0.0:9100` (a deliberate opt-in) and firewall the port.

## 2. Point Prometheus at it

Add a scrape job to `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: packetwyrm
    static_configs:
      - targets: ["127.0.0.1:9100"]
```

Confirm the target is UP under **Status -> Targets** and that
`curl -s http://127.0.0.1:9100/metrics` returns the `packetwyrm_*` series.

## 3. Import the dashboard

In Grafana: **Dashboards -> New -> Import -> Upload JSON file**, choose
`packetwyrm-dashboard.json`, and select your Prometheus data source when
prompted (the dashboard uses a `DS_PROMETHEUS` datasource variable and a `card`
template variable populated from `label_values(packetwyrm_card_open, card)`).

The installed package ships this file at
`/usr/share/packetwyrm/grafana/packetwyrm-dashboard.json`.

## Exported metrics

Management-plane series:

| Metric                              | Type    | Labels     | Meaning |
|-------------------------------------|---------|------------|---------|
| `packetwyrm_build_info`             | gauge   | `version`  | Running build (always 1) |
| `packetwyrm_card_open`              | gauge   | `card`     | 1 = card backend open |
| `packetwyrm_card_temp_celsius`      | gauge   | `card`     | FPGA die temperature (SYSMON) |
| `packetwyrm_card_vccint_volts`      | gauge   | `card`     | FPGA VCCINT rail |
| `packetwyrm_card_vccaux_volts`      | gauge   | `card`     | FPGA VCCAUX rail |
| `packetwyrm_card_error_sticky`      | gauge   | `card`     | 1 = a sticky error was latched |
| `packetwyrm_punt_to_tap_ok`         | counter | `card`     | Punt frames forwarded to host TAPs |
| `packetwyrm_punt_to_tap_dropped`    | counter | `card`     | Punt frames dropped on TAP write |
| `packetwyrm_tap_to_fpga_ok`         | counter | `card`     | TAP-read frames forwarded to slow-path TX |
| `packetwyrm_tap_to_fpga_dropped`    | counter | `card`     | TAP-read frames dropped |
| `packetwyrm_punt_unknown_lif`       | counter | `card`     | Punts with an unbound `logical_if_id` |

Per-port wire series (labeled `card`,`port`; straight from the MAC counters):

| Metric                              | Type    | Meaning |
|-------------------------------------|---------|---------|
| `packetwyrm_port_rx_frames` / `_tx_frames` | counter | Wire frame counts (derive pps via `rate()`) |
| `packetwyrm_port_rx_bytes` / `_tx_bytes`   | counter | Wire byte counts (derive bps via `rate()*8`) |
| `packetwyrm_port_rx_fcs_errors`     | counter | FCS/CRC errors |
| `packetwyrm_port_rx_bad_frames`     | counter | Real RX drops (SAF buffer overflow) |
| `packetwyrm_port_rx_oversize` / `_rx_undersize` | counter | Malformed-length frames |
| `packetwyrm_port_rx_unmatched`      | counter | No classifier match (informational, not a drop) |
| `packetwyrm_port_link_up_events` / `_link_down_events` | counter | Link transitions |
| `packetwyrm_port_block_lock_loss`   | counter | PCS block-lock loss events |

SFP+ optics series (labeled `card`,`port`; from the background DOM cache, so no
I2C on the scrape path; present only for a seated DOM-capable module):

| Metric                              | Type  | Meaning |
|-------------------------------------|-------|---------|
| `packetwyrm_sfp_present`            | gauge | 1 = module seated |
| `packetwyrm_sfp_temp_celsius`       | gauge | Module temperature |
| `packetwyrm_sfp_vcc_volts`          | gauge | Module supply voltage |
| `packetwyrm_sfp_tx_bias_ma`         | gauge | Laser bias current |
| `packetwyrm_sfp_tx_power_dbm` / `_rx_power_dbm` | gauge | Optical power (mW converted to dBm) |

Per-flow measurement series (present once a test config is loaded; labeled by
`flow` id and `name`). These come from the same snapshot the `flow.stats` RPC
uses, so the dashboard, CLI, and GUI always agree:

| Metric                                | Type    | Labels             | Meaning |
|---------------------------------------|---------|--------------------|---------|
| `packetwyrm_flow_tx_frames` / `_rx_frames` | counter | `flow`,`name` | Frame counts |
| `packetwyrm_flow_tx_bytes` / `_rx_bytes`   | counter | `flow`,`name` | Byte counts (bps via `rate()*8`) |
| `packetwyrm_flow_lost_packets`        | counter | `flow`,`name`      | Estimated lost packets |
| `packetwyrm_flow_duplicate_packets`   | counter | `flow`,`name`      | Duplicate packets |
| `packetwyrm_flow_out_of_order_packets`| counter | `flow`,`name`      | Out-of-order packets |
| `packetwyrm_flow_sequence_gaps`       | counter | `flow`,`name`      | Sequence-gap events |
| `packetwyrm_flow_latency_samples`     | counter | `flow`,`name`      | Latency samples measured |
| `packetwyrm_flow_running`             | gauge   | `flow`,`name`      | 1 = generator enabled |
| `packetwyrm_flow_latency_ns`          | gauge   | `flow`,`name`,`stat` | One-way latency; `stat` ∈ {min,avg,max} |
| `packetwyrm_flow_jitter_ns`           | gauge   | `flow`,`name`,`stat` | Delay variation; `stat` ∈ {min,avg,max} |

The bundled dashboard (`PacketWyrm`) has rows for Overview (fleet stats),
Throughput, Latency & jitter, Loss & integrity, Ports (wire), Hardware health
(FPGA temp/rails + SFP optics), and Slow path / control plane, with `flow` and
`card` template variables to filter. Rates (bps/pps) are derived in Grafana via
`rate(...)`, so the window is the panel's, not a fixed daemon interval.
