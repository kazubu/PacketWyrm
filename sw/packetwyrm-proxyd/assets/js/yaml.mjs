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

/* ---- validation --------------------------------------------------------- */
/* Client-side YAML syntax check via the vendored js-yaml (window.jsyaml). Gives
 * an immediate line number before we round-trip to the daemon. Returns
 * {ok:true} or {ok:false, line, msg}. If the lib is somehow absent, we don't
 * block (the daemon still validates). */
export function validateYaml(text) {
  const j = (typeof window !== "undefined") ? window.jsyaml : undefined;
  if (!j) return { ok: true };
  try { j.load(text); return { ok: true }; }
  catch (e) {
    const line = (e && e.mark && typeof e.mark.line === "number") ? e.mark.line + 1 : null;
    return { ok: false, line, msg: (e && (e.reason || e.message)) || "invalid YAML" };
  }
}

const isBlank = v => v === "" || v == null;
const asInt = v => (typeof v === "number") ? v : Number(String(v).trim());
const RE_MAC = /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/;
const RE_HEX = /^(0x)?[0-9a-fA-F]+$/;
function intRange(v, lo, hi) {
  const n = asInt(v);
  return (Number.isInteger(n) && n >= lo && n <= hi) ? null : `must be an integer ${lo}–${hi}`;
}
// Per-field-KEY validator (keys are the model keys used by the form). Blank is
// accepted for optional fields; required ones are enforced by range.
const CHECK = {
  src_mac: v => RE_MAC.test(String(v)) ? null : "not a MAC (aa:bb:cc:dd:ee:ff)",
  dst_mac: v => RE_MAC.test(String(v)) ? null : "not a MAC (aa:bb:cc:dd:ee:ff)",
  inner_src_mac: v => isBlank(v) ? null : (RE_MAC.test(String(v)) ? null : "not a MAC"),
  inner_dst_mac: v => isBlank(v) ? null : (RE_MAC.test(String(v)) ? null : "not a MAC"),
  sport: v => intRange(v, 0, 65535), dport: v => intRange(v, 0, 65535),
  ttl:   v => isBlank(v) ? null : intRange(v, 0, 255),
  vlan:  v => isBlank(v) ? null : intRange(v, 0, 4095),
  dscp:  v => isBlank(v) ? null : intRange(v, 0, 63),
  frame_len: v => intRange(v, 1, 16384),
  id: v => intRange(v, 0, 4294967295), tx: v => intRange(v, 0, 4095), rx: v => intRange(v, 0, 4095),
  rate: v => intRange(v, 0, Number.MAX_SAFE_INTEGER),
  tcp_flags: v => isBlank(v) ? null : (RE_HEX.test(String(v)) ? null : "hex (e.g. 0x18)"),
  ethertype: v => isBlank(v) ? null : (RE_HEX.test(String(v)) ? null : "hex (e.g. 0x0800)"),
  udp_dst: v => isBlank(v) ? null : (RE_HEX.test(String(v)) ? null : "hex mask"),
  ipv4_dst: v => isBlank(v) ? null : (RE_HEX.test(String(v)) ? null : "hex mask"),
  ipv6_dst_prefix: v => isBlank(v) ? null : intRange(v, 0, 128),
  ipv6_src_prefix: v => isBlank(v) ? null : intRange(v, 0, 128),
  mask: v => isBlank(v) ? null : ((RE_HEX.test(String(v)) || String(v).includes(":")) ? null : "hex or IPv6 literal"),
};
// Returns an error string for (key,value) or null. Unvalidated keys -> null.
export function fieldError(key, value) {
  return CHECK[key] ? CHECK[key](value) : null;
}
// Aggregate the human-readable errors for a whole flow (for Apply blocking).
export function flowErrors(f) {
  const errs = [];
  const chk = (label, key, val) => { const e = fieldError(key, val); if (e) errs.push(`flow ${f.id} ${label}: ${e}`); };
  chk("src_mac", "src_mac", f.src_mac); chk("dst_mac", "dst_mac", f.dst_mac);
  chk("src port", "sport", f.sport);    chk("dst port", "dport", f.dport);
  chk("ttl", "ttl", f.ttl); chk("vlan", "vlan", f.vlan); chk("frame_len", "frame_len", f.frame_len);
  chk("tx port", "tx", f.tx); chk("rx port", "rx", f.rx);
  if (f.l4 === "tcp") chk("tcp_flags", "tcp_flags", f.tcp_flags);
  chk("ethertype", "ethertype", f.ethertype);
  const e = f.encap || {};
  if (e.type && e.type !== "none") {
    chk("encap ttl", "ttl", e.ttl); chk("encap dscp", "dscp", e.dscp);
    chk("encap inner src_mac", "inner_src_mac", e.inner_src_mac);
    chk("encap inner dst_mac", "inner_dst_mac", e.inner_dst_mac);
  }
  // advanced: match masks + modifier masks (these can also go red inline, so
  // aggregate them here too -- otherwise a red field would still let Apply run).
  const m = f.match || {};
  ["udp_dst", "ipv4_dst", "ipv6_dst_prefix", "ipv6_src_prefix"].forEach(k => {
    const e2 = fieldError(k, m[k]); if (e2) errs.push(`flow ${f.id} match.${k}: ${e2}`);
  });
  const mods = f.mods || {};
  Object.keys(mods).forEach(k => {
    const e2 = fieldError("mask", mods[k] && mods[k].mask);
    if (e2) errs.push(`flow ${f.id} mod ${k} mask: ${e2}`);
  });
  return errs;
}

// Forwards use their OWN validator table: `udp_dst` here is a destination PORT
// (not a hex classifier mask like in flows), so it must not share flows' CHECK.
const FWD_CHECK = {
  ingress: v => intRange(v, 0, 4095), egress: v => intRange(v, 0, 4095),
  priority: v => isBlank(v) ? null : intRange(v, 0, 65535),
  ethertype: v => isBlank(v) ? null : (RE_HEX.test(String(v)) ? null : "hex (e.g. 0x0800)"),
  ip_proto: v => isBlank(v) ? null : intRange(v, 0, 255),
  udp_dst: v => isBlank(v) ? null : intRange(v, 0, 65535),
  vlan: v => isBlank(v) ? null : intRange(v, 0, 4095),
};
export function fwdFieldError(key, value) { return FWD_CHECK[key] ? FWD_CHECK[key](value) : null; }
export function fwdErrors(r) {
  const errs = [];
  const who = r.name || `${r.ingress}→${r.egress}`;
  const chk = (label, key, val) => { const e = fwdFieldError(key, val); if (e) errs.push(`forward ${who} ${label}: ${e}`); };
  chk("ingress", "ingress", r.ingress); chk("egress", "egress", r.egress);
  chk("priority", "priority", r.priority); chk("ethertype", "ethertype", r.ethertype);
  chk("ip_proto", "ip_proto", r.ip_proto); chk("udp_dst", "udp_dst", r.udp_dst); chk("vlan", "vlan", r.vlan);
  return errs;
}
