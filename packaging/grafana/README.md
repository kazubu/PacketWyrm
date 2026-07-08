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
| `packetwyrm_punt_to_tap_ok`         | counter | `card`     | Punt frames forwarded to host TAPs |
| `packetwyrm_punt_to_tap_dropped`    | counter | `card`     | Punt frames dropped on TAP write |
| `packetwyrm_tap_to_fpga_ok`         | counter | `card`     | TAP-read frames forwarded to slow-path TX |
| `packetwyrm_tap_to_fpga_dropped`    | counter | `card`     | TAP-read frames dropped |
| `packetwyrm_punt_unknown_lif`       | counter | `card`     | Punts with an unbound `logical_if_id` |

Per-flow measurement series (present once a test config is loaded; labeled by
`flow` id and `name`). These come from the same snapshot the `flow.stats` RPC
uses, so the dashboard, CLI, and GUI always agree:

| Metric                                | Type    | Labels             | Meaning |
|---------------------------------------|---------|--------------------|---------|
| `packetwyrm_flow_tx_frames`           | counter | `flow`,`name`      | Frames transmitted |
| `packetwyrm_flow_rx_frames`           | counter | `flow`,`name`      | Frames received |
| `packetwyrm_flow_tx_bytes`            | counter | `flow`,`name`      | Bytes transmitted (derive bps via `rate()*8`) |
| `packetwyrm_flow_rx_bytes`            | counter | `flow`,`name`      | Bytes received |
| `packetwyrm_flow_lost_packets`        | counter | `flow`,`name`      | Estimated lost packets |
| `packetwyrm_flow_duplicate_packets`   | counter | `flow`,`name`      | Duplicate packets |
| `packetwyrm_flow_out_of_order_packets`| counter | `flow`,`name`      | Out-of-order packets |
| `packetwyrm_flow_latency_ns`          | gauge   | `flow`,`name`,`stat` | One-way latency; `stat` ∈ {min,avg,max} |

The bundled dashboard has timeseries panels for per-flow bps, loss/dup/ooo, and
latency, plus a red-on-error total-errors stat. Note bps is derived in Grafana
(`rate(packetwyrm_flow_tx_bytes[$__rate_interval]) * 8`) rather than exported
directly, so the rate window is the panel's, not a fixed daemon interval.
