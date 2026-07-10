# Monitoring (Prometheus + Grafana)

PacketWyrm ships a built-in Prometheus exporter and a ready-made
Grafana dashboard, so a running daemon becomes a live throughput /
latency / loss / hardware-health board with no extra agents. This
guide is the operator orientation; for import mechanics and the full
metric table see [`packaging/grafana/README.md`](../../packaging/grafana/README.md),
and for the underlying RPC snapshot the metrics come from see
[`../design/rpc-protocol.md`](../design/rpc-protocol.md).

## The exporter

`packetwyrmd -p [ADDR:]PORT` binds a Prometheus `/metrics` endpoint.
`ADDR` defaults to `127.0.0.1`; use `0.0.0.0:PORT` to expose it on all
interfaces — it is **unauthenticated**, so opt in deliberately and
firewall the port. A value of `0` (or leaving `-p` off) disables it.
The packaged systemd unit runs it on `127.0.0.1:9100`.

```sh
sudo sw/build/packetwyrmd -v -s 5000 -p 9100 \
    -c /etc/packetwyrm/packetwyrm.yaml
curl -s http://127.0.0.1:9100/metrics | grep packetwyrm_ | head
```

What's exported (labels in parentheses), one line each:

- **Card / FPGA health:** `packetwyrm_build_info`(`version`),
  `packetwyrm_card_open`(`card`), `packetwyrm_card_temp_celsius`(`card`),
  `packetwyrm_card_vccint_volts` / `_vccaux_volts`(`card`),
  `packetwyrm_card_error_sticky`(`card`).
- **Per-port wire counters** (`card`,`port`):
  `packetwyrm_port_rx_frames` / `_tx_frames`, `_rx_bytes` / `_tx_bytes`,
  `_rx_fcs_errors`, `_rx_bad_frames`, `_rx_oversize` / `_rx_undersize`,
  `_rx_unmatched`, `_link_up_events` / `_link_down_events`,
  `_block_lock_loss`.
- **SFP optics** (`card`,`port`; from the DOM cache, present only for a
  seated DOM-capable module — a DAC / copper module has none):
  `packetwyrm_sfp_present`, `_temp_celsius`, `_vcc_volts`, `_tx_bias_ma`,
  `_tx_power_dbm` / `_rx_power_dbm`.
- **Per-flow** (`flow`,`name`; present once a test config is loaded):
  `packetwyrm_flow_tx_frames` / `_rx_frames`, `_tx_bytes` / `_rx_bytes`,
  `_lost_packets`, `_duplicate_packets`, `_out_of_order_packets`,
  `_sequence_gaps`, `_latency_samples`, `_running`,
  `_latency_ns`(`stat=min|avg|max`), `_jitter_ns`(`stat=min|avg|max`).

Rates (bps / pps) are not exported directly — derive them in the
dashboard with `rate()`, e.g. bits per second is
`rate(packetwyrm_flow_tx_bytes[$__rate_interval]) * 8`. The full metric
table (types and per-series meaning) lives in
[`packaging/grafana/README.md`](../../packaging/grafana/README.md).

## Point Prometheus at it

A minimal `prometheus.yml` scrape config:

```yaml
scrape_configs:
  - job_name: packetwyrm
    scrape_interval: 5s
    static_configs:
      - targets: ["127.0.0.1:9100"]
```

Confirm the target is **UP** under Prometheus's *Status -> Targets*.

## The bundled Grafana dashboard

The package installs `packetwyrm-dashboard.json` under
`/usr/share/packetwyrm/grafana/` (also in the repo at
[`packaging/grafana/`](../../packaging/grafana/)). Its rows are:

- **Overview** — fleet stat tiles: flows running, aggregate tx/rx bps
  and pps, total errors, loss in ppm, worst / average latency, FPGA
  temperature.
- **Throughput** — per-flow and per-port bps / pps over time.
- **Latency & jitter** — one-way latency and delay variation
  (min/avg/max).
- **Loss & integrity** — lost / duplicate / out-of-order packets and
  sequence gaps.
- **Ports (wire)** — MAC-level frame/byte counts, FCS/bad/oversize/
  undersize, link and block-lock events.
- **Hardware health** — FPGA temperature and rails plus SFP optics.
- **Slow path / control plane** — punt / TAP forwarding counters.

The dashboard has `flow` and `card` template variables to filter. For
import steps (data-source selection, the installed path) see
[`packaging/grafana/README.md`](../../packaging/grafana/README.md).

## Quick container setup (optional)

An **example** an operator can adapt — Prometheus and Grafana both on
`--network host` so Prometheus can scrape the loopback-bound exporter
and Grafana can reach Prometheus on `localhost`:

```sh
# prometheus.yml as above, in $PWD. datasource + dashboard provisioned.
docker run -d --name prometheus --network host \
    -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    prom/prometheus

mkdir -p prov/datasources prov/dashboards
cat > prov/datasources/ds.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF
cat > prov/dashboards/dash.yml <<'EOF'
apiVersion: 1
providers:
  - name: packetwyrm
    options: { path: /var/lib/grafana/dashboards }
EOF
docker run -d --name grafana --network host \
    -e GF_SECURITY_ADMIN_PASSWORD=change-me \
    -v "$PWD/prov/datasources:/etc/grafana/provisioning/datasources:ro" \
    -v "$PWD/prov/dashboards:/etc/grafana/provisioning/dashboards:ro" \
    -v "$PWD/packaging/grafana:/var/lib/grafana/dashboards:ro" \
    grafana/grafana
# Grafana on http://localhost:3000 (admin / change-me).
```

Exposure caveats: `--network host` puts both services on all
interfaces, so bind / firewall them and change the Grafana admin
password from the placeholder above. Keep the exporter itself on
`127.0.0.1` unless you have a reason to expose it.

## CLI alternative

For a quick look without Prometheus, the same numbers are live from the
CLI:

```sh
pktwyrm flow stats      # per-flow tx/rx, loss, latency summary
pktwyrm latency         # one-way latency per flow
pktwyrm hist latency    # latency histogram
pktwyrm stats           # per-card host-plane / port counters
```

See the [CLI reference](cli-reference.md) (or `pktwyrm --help`) for the full
command set.
