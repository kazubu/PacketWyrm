/* Test-config YAML emitter (form model -> YAML string; the daemon validates).
 * NOTE: emit-only for now; Phase 3 will move to js-yaml for round-trip parsing. */
import { state } from "./state.mjs";

const yq = v => (typeof v === "string") ? JSON.stringify(v) : String(v);

// A modifier mask is either a hex/decimal number (MAC/IPv4/port/vlan) or an
// IPv6 address literal (contains ':'); quote the latter, emit the former raw.
function maskval(v) {
  const s = String(v);
  return s.includes(":") ? JSON.stringify(s) : s;
}

export function flowYaml(f) {
  const L = [];
  L.push(`  - id: ${f.id}`);
  if (f.name) L.push(`    name: ${yq(f.name)}`);
  L.push(`    tx_global_port: ${f.tx}`);
  L.push(`    rx_global_port: ${f.rx}`);
  const raw = f.frame_template && f.frame_template !== "test";
  L.push(`    l2:`);
  L.push(`      src_mac: ${yq(f.src_mac)}`);
  L.push(`      dst_mac: ${yq(f.dst_mac)}`);
  if (f.vlan !== "" && f.vlan != null) L.push(`      vlan: ${f.vlan}`);
  if (f.ethertype !== "" && f.ethertype != null) L.push(`      ethertype: ${f.ethertype}`);
  if (f.l3 === "ipv6") {
    L.push(`    ipv6:`);
    L.push(`      src: ${yq(f.ip_src)}`); L.push(`      dst: ${yq(f.ip_dst)}`);
    if (f.ttl) L.push(`      hop_limit: ${f.ttl}`);
  } else {
    L.push(`    ipv4:`);
    L.push(`      src: ${yq(f.ip_src)}`); L.push(`      dst: ${yq(f.ip_dst)}`);
    if (f.ttl) L.push(`      ttl: ${f.ttl}`);
  }
  L.push(`    ${f.l4}:`);
  L.push(`      src_port: ${f.sport}`); L.push(`      dst_port: ${f.dport}`);
  if (f.l4 === "tcp" && f.tcp_flags) L.push(`      flags: ${f.tcp_flags}`);
  L.push(`    traffic:`);
  L.push(`      frame_len: ${f.frame_len}`);
  L.push(`      ${f.rate_mode === "pps" ? "rate_pps" : "rate_bps"}: ${f.rate}`);
  L.push(`      payload: ${yq(f.payload)}`);
  L.push(`      insert_sequence: ${!!f.seq}`);
  L.push(`      insert_timestamp: ${!!f.ts}`);
  if (raw) L.push(`      frame_template: ${yq(f.frame_template)}`);
  // Raw templates carry no test header: no measurements, and RX must classify
  // on header fields (the daemon validator enforces this -- emit valid YAML).
  if (!raw) {
    L.push(`    measurements:`);
    L.push(`      loss: ${!!f.m_loss}`);
    L.push(`      latency: ${!!f.m_lat}`);
    L.push(`      jitter: ${!!f.m_jit}`);
  }
  if (raw) L.push(`    classify: header`);
  else if (f.classify && f.classify !== "map") L.push(`    classify: ${yq(f.classify)}`);
  if (f.background) L.push(`    background: true`);
  // match: emit only the set fields (masks are hex; prefixes are ints)
  const m = f.match || {}, ml = [];
  const setv = v => v !== "" && v != null;
  if (setv(m.udp_dst))          ml.push(`      udp_dst: ${m.udp_dst}`);
  if (setv(m.ipv4_dst))         ml.push(`      ipv4_dst: ${m.ipv4_dst}`);
  if (setv(m.ipv6_dst_prefix))  ml.push(`      ipv6_dst_prefix: ${m.ipv6_dst_prefix}`);
  if (setv(m.ipv6_src_prefix))  ml.push(`      ipv6_src_prefix: ${m.ipv6_src_prefix}`);
  if (ml.length) { L.push(`    match:`); L.push(...ml); }
  // modifiers: emit only non-static fields
  const mods = f.mods || {}, dl = [];
  for (const k of Object.keys(mods)) {
    const md = mods[k];
    if (!md || !md.mode || md.mode === "static") continue;
    let s = `      ${k}: { mode: ${yq(md.mode)}`;
    if (setv(md.mask)) s += `, mask: ${maskval(md.mask)}`;
    dl.push(s + ` }`);
  }
  if (dl.length) { L.push(`    modifiers:`); L.push(...dl); }
  // encap
  const e = f.encap || {};
  if (e.type && e.type !== "none") {
    L.push(`    encap:`);
    L.push(`      type: ${yq(e.type)}`);
    L.push(`      outer:`);
    const fam = e.l3 === "ipv6" ? "ipv6" : "ipv4";
    let o = `        ${fam}: { src: ${yq(e.src)}, dst: ${yq(e.dst)}`;
    if (setv(e.ttl))  o += fam === "ipv6" ? `, hop_limit: ${e.ttl}` : `, ttl: ${e.ttl}`;
    if (setv(e.dscp)) o += `, dscp: ${e.dscp}`;
    L.push(o + ` }`);
    if (e.type === "etherip" && (e.inner_src_mac || e.inner_dst_mac))
      L.push(`      inner_l2: { src_mac: ${yq(e.inner_src_mac)}, dst_mac: ${yq(e.inner_dst_mac)} }`);
    if (f.rx_expect && f.rx_expect !== "inner") L.push(`    rx_expect: ${yq(f.rx_expect)}`);
  }
  return L.join("\n");
}

export function fwdYaml(r) {
  const L = [`  - ingress_port: ${r.ingress}`, `    egress_port: ${r.egress}`];
  if (r.name) L.push(`    name: ${yq(r.name)}`);
  if (r.priority !== "" && r.priority != null) L.push(`    priority: ${r.priority}`);
  for (const [k, key] of [["ethertype", "ethertype"], ["ip_proto", "ip_proto"],
                          ["udp_dst", "udp_dst"], ["vlan", "vlan"]])
    if (r[k] !== "" && r[k] != null) L.push(`    ${key}: ${r[k]}`);
  for (const k of ["ipv6_dst", "ipv6_src"]) if (r[k]) L.push(`    ${k}: ${yq(r[k])}`);
  return L.join("\n");
}

export function buildTestYaml() {
  let out = "";
  if (state.flows.length) out += "flows:\n" + state.flows.map(flowYaml).join("\n") + "\n";
  if (state.fwds.length)  out += "forwards:\n" + state.fwds.map(fwdYaml).join("\n") + "\n";
  return out || "flows: []\n";
}
