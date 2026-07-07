/* Dashboard: live polling + rendering (cards / ports / SFP / TAPs / flow stats /
 * aggregate / health / latency histogram). Rates use each source's own FPGA
 * timestamp; NO smoothing (the momentary value is what a tester wants to see). */
import { $, el } from "./dom.mjs";
import { rpc, setConn } from "./rpc.mjs";
import { TICK_NS, fmt3, fmtTime, fmtRate } from "./format.mjs";
import { statePill } from "./ui.mjs";
import { healthSeenErr } from "./state.mjs";

function tableFrom(rows, cols) {
  const t = el("table");
  t.append(el("tr", {}, cols.map(c => el("th", { class: c.num ? "num" : "", text: c.h }))));
  rows.forEach(row => t.append(el("tr", {}, cols.map(c => {
    const v = c.get(row);
    return el("td", { class: c.num ? "num" : "", text: v == null ? "—" : String(v) });
  }))));
  return t;
}
function setBox(id, node) { const b = $(id); b.innerHTML = ""; b.append(node); }
// numeric cell that goes red when non-zero (for error counters)
function errTd(v) {
  const td = el("td", { class: "num", text: v == null ? "—" : String(v) });
  if (Number(v) > 0) td.style.color = "var(--err)";
  return td;
}

// rate tracking: previous per-flow / per-port counters. Rates are measured over
// the FPGA free-running timestamp (6.4 ns/tick) so they don't depend on browser
// poll jitter. Each snapshot source (flow.stats, ports.stats) carries its OWN
// timestamp -- we must divide a source's counter delta by THAT source's ts
// delta, never another's (they snapshot at different instants -> jitter).
let ratePrev = new Map(), rateT = 0, portPrev = new Map();
const tsPrev = {};                       // per-source previous 64-bit tick (BigInt)
// Full 64-bit FPGA timestamp (ticks) from the lo/hi pair. Both halves avoid the
// ~27.5 s wrap of the low 32 bits (156.25 MHz) over a long/backgrounded poll.
function fpgaTicks(lo, hi) {
  if (lo == null) return null;
  return (BigInt(hi >>> 0) << 32n) | BigInt(lo >>> 0);
}
// Seconds since this source's previous snapshot, from its own fpga_ts (falls
// back to wall-clock only if the timestamp is missing/non-monotonic).
function intervalSec(src, lo, hi, wallNow) {
  const cur = fpgaTicks(lo, hi);
  let dt = 0;
  if (cur != null && tsPrev[src] != null) {
    const d = cur - tsPrev[src];
    if (d > 0n) dt = Number(d) * 6.4e-9;
  }
  if (cur != null) tsPrev[src] = cur;
  if (dt === 0) dt = rateT ? (wallNow - rateT) / 1000 : 0;
  return dt;
}

async function pollVersions(cards) {
  const rows = [];
  const ver = await rpc({ rpc: "version" });
  rows.push({ comp: "packetwyrmd", ver: ver.version || "?" });
  try { const pv = await (await fetch("/proxyd/version")).json(); rows.push({ comp: "packetwyrm-proxyd", ver: pv.version || "?" }); }
  catch (e) { rows.push({ comp: "packetwyrm-proxyd", ver: "?" }); }
  (cards || []).forEach(c => {
    if (c.fpga_version != null)
      rows.push({ comp: `card ${c.id} FPGA`,
        ver: `v${c.fpga_version}  build ${c.build_id || "?"}  dev ${c.device_id || "?"}  git ${c.git_hash || "?"}` });
    if (c.temp_c != null) {
      // Each rail is reported by the daemon only once its SYSMON code is valid,
      // so format per field ("—" when a rail hasn't been sampled yet).
      const volt = (v) => v != null ? `${fmt3(v)} V` : "—";
      rows.push({ comp: `card ${c.id} SYSMON`,
        ver: `${fmt3(c.temp_c)} °C   VCCINT ${volt(c.vccint_v)}   VCCAUX ${volt(c.vccaux_v)}` });
    }
  });
  setBox("#d-versions", tableFrom(rows, [
    { h: "component", get: r => r.comp }, { h: "version", get: r => r.ver }]));
}

function renderHealth(cards, stats, fstats, metaById, portstats) {
  const box = $("#d-health"); box.innerHTML = "";
  const t = el("table");
  t.append(el("tr", {}, ["card", "LED", "causes"].map(h => el("th", { text: h }))));
  (cards || []).forEach(c => {
    const causes = [];
    const infos  = [];   // informational (not an error, does not light the LED)
    let cardUnmatched = 0;   // total no-match frames on this card (candidate latch cause)
    // per-card host-plane drops
    const s = (stats || []).find(x => x.card_id === c.id);
    if (s) {
      if (s.punt_to_tap_dropped > 0) causes.push(`punt drops ${s.punt_to_tap_dropped}`);
      if (s.tap_to_fpga_dropped > 0) causes.push(`inject drops ${s.tap_to_fpga_dropped}`);
      if (s.punt_unknown_lif > 0)    causes.push(`unknown-lif ${s.punt_unknown_lif}`);
    }
    // per-port FCS / data-plane drops on this card — the two per-port inputs to
    // err_sticky that the per-flow counters don't show.
    (portstats || []).forEach(p => {
      if (p.card_id !== c.id) return;
      if (p.rx_fcs_error > 0) causes.push(`port ${p.global_port} FCS ${p.rx_fcs_error}`);
      // Real drops = store-and-forward buffer overflow. These DO light the LED.
      if (p.drops > 0) causes.push(`port ${p.global_port} drops ${p.drops} (saf-overflow)`);
      // Unmatched frames: a STRAY no-match (non-test, e.g. host ICMPv6 ND/MLD)
      // is informational and does NOT light the LED. But a no-match on a real
      // TEST frame DOES light the LED (that frame never reached the checker, so
      // no loss event fires) -- mirror the RTL err_sticky here so the GUI health
      // breakdown agrees with the front-panel LED. last_unmatched carries the
      // most recent miss's identity; is_test => promote to a health cause.
      if (p.rx_unmatched > 0) {
        cardUnmatched += p.rx_unmatched;
        const ld = p.last_unmatched;
        const ident = ld
          ? ` [last: ${ld.is_test ? "test" : "non-test"} eth 0x${(ld.ethertype || 0).toString(16)} proto ${ld.l3_proto} flow ${ld.flow_id}]`
          : "";
        const u = `port ${p.global_port} unmatched ${p.rx_unmatched}${ident}`;
        // A no-match on a real TEST frame latches err_sticky (RTL). If the last
        // captured miss is still a test frame, show it as a concrete cause. Note
        // last_unmatched is overwritten by later stray misses, so once err_sticky
        // is red we ALSO flag unmatched as a candidate cause below (cardUnmatched).
        if (ld && ld.is_test) causes.push(`port ${p.global_port} TEST-frame no-match ${p.rx_unmatched}${ident}`);
        else                  infos.push(u);
      }
    });
    // per-flow errors on flows received by this card
    let active = false;
    (fstats || []).forEach(f => {
      if (f.rx_card_id !== c.id) return;
      if (f.rx_frames > 0) active = true;
      if (f.lost > 0) causes.push(`flow ${f.id} lost ${f.lost}`);
      if (f.duplicate > 0) causes.push(`flow ${f.id} dup ${f.duplicate}`);
      if (f.out_of_order > 0) causes.push(`flow ${f.id} reorder ${f.out_of_order}`);
    });
    // Authoritative LED state = the FPGA's err_sticky bit (when the bitstream
    // exposes it). It latches on ANY error since the last stats.clear, so it
    // can be red even when the live counters above read clean.
    const hwErr = c.err_sticky === true;
    const derivedErr = causes.length > 0;
    if (derivedErr || hwErr) healthSeenErr.add(c.id);
    const sticky = !derivedErr && !hwErr && healthSeenErr.has(c.id);
    let led, note;
    if (!c.open) { led = el("span", { class: "led off", text: "● card closed" }); note = "—"; }
    else if (hwErr) {
      led = el("span", { class: "led red", text: "● red (err_sticky)" });
      // If no concrete live cause remains but the card saw no-match frames, a
      // past TEST-frame no-match is the likely latch cause (its last_unmatched
      // context may have since been overwritten by a stray non-test miss).
      const cand = (!causes.length && cardUnmatched > 0)
        ? `possible cause: a TEST-frame no-match earlier (unmatched ${cardUnmatched}) — ` : "";
      note = (causes.length ? causes.join(", ") + " — " : cand)
        + "LED latched; live counters may read clean (transient/FCS/TEST no-match). stats.clear resets it.";
    }
    else if (derivedErr) { led = el("span", { class: "led red", text: "● error" }); note = causes.join(", "); }
    else if (sticky) { led = el("span", { class: "led amber", text: "● clean now (error seen earlier)" });
      note = "an error occurred earlier this session — the physical LED likely stays red until stats.clear"; }
    else { led = el("span", { class: "led grn", text: active ? "● ok (traffic)" : "● ok (idle)" }); note = "—"; }
    // Informational notes (unmatched frames etc.) are shown regardless of LED
    // state and never turn the LED red.
    if (infos.length) {
      const infoStr = "info: " + infos.join(", ");
      note = (note && note !== "—") ? note + " · " + infoStr : infoStr;
    }
    t.append(el("tr", {}, [el("td", { text: c.id }), el("td", {}, [led]),
      el("td", { class: (hwErr || derivedErr || sticky) ? "" : "muted", text: note })]));
  });
  box.append(t);
  box.append(el("div", { class: "muted", style: "margin-top:6px",
    text: "“red (err_sticky)” is the FPGA's actual LED bit (GLOBAL_STATUS) when the "
       + "bitstream exposes it — it latches on ANY lost/decode/FCS error since the last "
       + "stats.clear, so it can be red while the live counters read clean (a transient at "
       + "arm, or a per-port FCS error). Run stats.clear (Control tab) to reset it. On an "
       + "older bitstream without the readback, health is inferred from the live counters." }));
}

// latency cell: "—" unless the flow reports valid latency with the field present
const lat = (f, k) =>
  (f.latency_valid && f[k] != null) ? fmtTime(f[k] * TICK_NS) : "—";
function renderFlowStatsTable(fstats, rates) {
  const cols = ["id", "state", "path (tx→rx)", "tx frm", "tx pps", "tx bps", "rx frm", "rx pps", "rx bps", "lost", "dup", "reorder", "min", "avg", "max"];
  const t = el("table");
  t.append(el("tr", {}, cols.map(h => el("th", { class: /frm|pps|bps|lost|dup|reorder|min|avg|max/.test(h) ? "num" : "", text: h }))));
  fstats.forEach(f => {
    const rt = rates.get(f.id) || {};
    t.append(el("tr", {}, [
      el("td", { class: "num", text: f.id }),
      el("td", {}, [statePill(!!f.enabled)]),
      el("td", { class: "path", text: `${f.tx_port || "?"} → ${f.rx_port || "?"}` }),
      el("td", { class: "num", text: f.tx_frames }),
      el("td", { class: "num", text: fmtRate(rt.tx) }),
      el("td", { class: "num", text: rt.txb != null ? fmtRate(rt.txb).replace("/s", "bps") : "—" }),
      el("td", { class: "num", text: f.rx_frames }),
      el("td", { class: "num", text: fmtRate(rt.rx) }),
      el("td", { class: "num", text: rt.rxb != null ? fmtRate(rt.rxb).replace("/s", "bps") : "—" }),
      errTd(f.lost), errTd(f.duplicate), errTd(f.out_of_order),
      // latency fields are absent when read_ok/latency_valid is false -> show —
      el("td", { class: "num", text: lat(f, "min_latency") }),
      el("td", { class: "num", text: lat(f, "avg_latency") }),
      el("td", { class: "num", text: lat(f, "max_latency") }),
    ]));
  });
  return t;
}

function renderAggregate(fstats, rates, metaById) {
  // group counters + rates by total / rx-card / rx-port
  const groups = new Map();  // label -> {tx,rx,lost,dup,txr,rxr,order}
  const bump = (label, f, order) => {
    let g = groups.get(label);
    if (!g) { g = { tx: 0, rx: 0, lost: 0, dup: 0, txr: 0, rxr: 0, order }; groups.set(label, g); }
    const rt = rates.get(f.id) || {};
    g.tx += f.tx_frames || 0; g.rx += f.rx_frames || 0;
    g.lost += f.lost || 0; g.dup += f.duplicate || 0;
    g.txr += rt.tx || 0; g.rxr += rt.rx || 0;
  };
  fstats.forEach(f => {
    bump("Total", f, 0);
    bump(`card ${f.rx_card_id}`, f, 1);
    const m = metaById.get(f.id);
    if (m) bump(`port ${m.rx}`, f, 2);
  });
  const rows = [...groups.entries()].map(([label, g]) => ({ label, ...g }))
    .sort((a, b) => a.order - b.order || a.label.localeCompare(b.label));
  const t = el("table");
  t.append(el("tr", {}, ["scope", "tx frm", "tx/s", "rx frm", "rx/s", "lost", "dup"]
    .map(h => el("th", { class: h === "scope" ? "" : "num", text: h }))));
  rows.forEach(r => t.append(el("tr", {}, [
    el("td", { text: r.label }),
    el("td", { class: "num", text: r.tx }), el("td", { class: "num", text: fmtRate(r.txr) }),
    el("td", { class: "num", text: r.rx }), el("td", { class: "num", text: fmtRate(r.rxr) }),
    errTd(r.lost), errTd(r.dup),
  ])));
  return t;
}

export async function poll() {
  try {
    const [cards, ports, sfp, fstats, flowsMeta, stats, pstats, taps] = await Promise.all([
      rpc({ rpc: "cards" }), rpc({ rpc: "ports" }), rpc({ rpc: "sfp.info" }),
      rpc({ rpc: "flow.stats" }), rpc({ rpc: "flows" }), rpc({ rpc: "stats" }),
      rpc({ rpc: "ports.stats" }), rpc({ rpc: "tap.stats" })]);
    if (cards.error) { setConn(false, cards.error); return; }

    const now = Date.now();
    const dtF = intervalSec("flow", fstats.fpga_ts_lo, fstats.fpga_ts_hi, now);
    const dtP = intervalSec("port", pstats.fpga_ts_lo, pstats.fpga_ts_hi, now);
    // per-flow instantaneous rate (frames + bytes -> pps + bps) over this poll's
    // own fpga_ts interval. No smoothing -- the momentary value is what's wanted.
    const rates = new Map();
    (fstats.flows || []).forEach(f => {
      const p = ratePrev.get(f.id);
      if (p && dtF > 0) rates.set(f.id, {
        tx:  Math.max(0, (f.tx_frames - p.tx) / dtF),
        rx:  Math.max(0, (f.rx_frames - p.rx) / dtF),
        txb: Math.max(0, (f.tx_bytes - p.txb) * 8 / dtF),
        rxb: Math.max(0, (f.rx_bytes - p.rxb) * 8 / dtF) });
      ratePrev.set(f.id, { tx: f.tx_frames, rx: f.rx_frames, txb: f.tx_bytes, rxb: f.rx_bytes });
    });
    // per-port instantaneous rate over ports.stats' own fpga_ts interval
    const prates = new Map();
    (pstats.ports || []).forEach(p => {
      const k = `${p.card_id}:${p.local_port}`, pv = portPrev.get(k);
      if (pv && dtP > 0) prates.set(k, {
        rxpps: Math.max(0, (p.rx_frames - pv.rxf) / dtP), txpps: Math.max(0, (p.tx_frames - pv.txf) / dtP),
        rxbps: Math.max(0, (p.rx_bytes - pv.rxb) * 8 / dtP), txbps: Math.max(0, (p.tx_bytes - pv.txb) * 8 / dtP) });
      portPrev.set(k, { rxf: p.rx_frames, txf: p.tx_frames, rxb: p.rx_bytes, txb: p.tx_bytes });
    });
    rateT = now;

    const metaById = new Map((flowsMeta.flows || []).map(f => [f.id,
      { name: f.name, tx: f.tx_global_port, rx: f.rx_global_port, enabled: f.enabled }]));

    if (cards.cards) {
      setBox("#d-cards", tableFrom(cards.cards, [
        { h: "id", get: r => r.id, num: 1 }, { h: "name", get: r => r.name }, { h: "pci", get: r => r.pci },
        { h: "backend", get: r => r.backend }, { h: "open", get: r => r.open }]));
      pollVersions(cards.cards);
      renderHealth(cards.cards, stats.stats, fstats.flows, metaById, pstats.ports);
    }
    // Ports table: prefer per-port MAC counters (ports.stats) with pps/bps;
    // fall back to the plain port map when the backend lacks port counters.
    if (pstats.ports && pstats.ports.length) {
      setBox("#d-ports", tableFrom(pstats.ports, [
        { h: "card", get: r => r.card_id, num: 1 }, { h: "port", get: r => r.global_port, num: 1 },
        { h: "rx pps", get: r => fmtRate(prates.get(`${r.card_id}:${r.local_port}`)?.rxpps), num: 1 },
        { h: "rx bps", get: r => fmtRate(prates.get(`${r.card_id}:${r.local_port}`)?.rxbps), num: 1 },
        { h: "tx pps", get: r => fmtRate(prates.get(`${r.card_id}:${r.local_port}`)?.txpps), num: 1 },
        { h: "tx bps", get: r => fmtRate(prates.get(`${r.card_id}:${r.local_port}`)?.txbps), num: 1 },
        { h: "rx frm", get: r => r.rx_frames, num: 1 }, { h: "tx frm", get: r => r.tx_frames, num: 1 },
        { h: "FCS", get: r => r.rx_fcs_error, num: 1 }, { h: "drops", get: r => r.drops, num: 1 },
        { h: "unmatched", get: r => r.rx_unmatched, num: 1 }]));
    } else if (ports.ports) setBox("#d-ports", tableFrom(ports.ports, [
      { h: "name", get: r => r.name }, { h: "card", get: r => r.card_id, num: 1 },
      { h: "local", get: r => r.local_port, num: 1 }, { h: "global", get: r => r.global_port, num: 1 }]));
    if (sfp.sfp) setBox("#d-sfp", tableFrom(sfp.sfp, [
      { h: "card", get: r => r.card_id, num: 1 }, { h: "port", get: r => r.port, num: 1 },
      { h: "present", get: r => r.present }, { h: "vendor", get: r => r.vendor }, { h: "part", get: r => r.part },
      { h: "temp°C", get: r => fmt3(r.temp_c), num: 1 }, { h: "Vcc", get: r => fmt3(r.vcc_v), num: 1 },
      { h: "tx mW", get: r => fmt3(r.tx_power_mw), num: 1 }, { h: "rx mW", get: r => fmt3(r.rx_power_mw), num: 1 }]));
    // Host-plane TAPs: the virtual NICs the daemon created per logical interface.
    if (taps && taps.taps) {
      if (taps.taps.length) setBox("#d-taps", tableFrom(taps.taps, [
        { h: "name", get: r => r.name }, { h: "lif", get: r => r.logical_if_id, num: 1 },
        { h: "mac", get: r => r.mac || "—" }, { h: "port", get: r => r.global_port, num: 1 },
        { h: "vlan", get: r => r.vlan, num: 1 },
        { h: "state", get: r => (r.admin_up ? "up" : "down") + (r.oper_up ? ",run" : "") },
        { h: "addrs", get: r => (r.addrs && r.addrs.length) ? r.addrs.join(" ") : "—" },
        { h: "→tap", get: r => r.bridge ? r.bridge.to_tap_ok : "—", num: 1 },
        { h: "→tap drop", get: r => r.bridge ? r.bridge.to_tap_dropped : "—", num: 1 },
        { h: "tap→", get: r => r.bridge ? r.bridge.from_tap_ok : "—", num: 1 },
        { h: "tap→ drop", get: r => r.bridge ? r.bridge.from_tap_dropped : "—", num: 1 }]));
      else setBox("#d-taps", el("div", { class: "muted", text: "no TAP interfaces (none configured, or daemon lacks CAP_NET_ADMIN)" }));
    }
    if (fstats.flows) {
      setBox("#d-agg", renderAggregate(fstats.flows, rates, metaById));
      setBox("#d-flowstats", renderFlowStatsTable(fstats.flows, rates));
      const sel = $("#hist-flow"); const cur = sel.value;
      sel.innerHTML = ""; fstats.flows.forEach(f => sel.append(el("option", { value: f.id, text: f.id })));
      if (cur) sel.value = cur;
    }
    setConn(true, "connected");
  } catch (e) { setConn(false, "no connection"); }
}

async function renderHist() {
  const id = $("#hist-flow").value;
  if (!id) return;
  const r = await rpc({ rpc: "flow.hist", id: Number(id) });
  const box = $("#d-hist"); box.innerHTML = "";
  if (!r.buckets) { box.append(el("div", { class: "muted", text: r.error || "no data" })); return; }
  const max = Math.max(1, ...r.buckets);
  r.buckets.forEach((c, i) => {
    if (c === 0 && i > 0 && i < r.buckets.length - 1) return; // skip empty middle bins
    // RTL log2_bucket = index of the highest set bit of the latency in ticks,
    // so bucket i holds latencies [2^i, 2^(i+1)) ticks (bucket 0 = [0, 2)).
    const loT = i === 0 ? 0 : Math.pow(2, i);     // bucket lower bound in ticks
    const hiT = Math.pow(2, i + 1);               // (2**(i+1), not 1<< -- avoids 32-bit overflow)
    const label = i === 0 ? `< ${fmtTime(hiT * TICK_NS)}` : `≥ ${fmtTime(loT * TICK_NS)}`;
    box.append(el("div", { class: "barrow" }, [
      el("span", { class: "lbl", text: label }),
      el("div", { class: "bar", style: `width:${(c / max * 100).toFixed(1)}%` }),
      el("span", { class: "cnt", text: c })]));
  });
}

export function initDashboard() {
  $("#hist-flow").addEventListener("change", renderHist);
}
