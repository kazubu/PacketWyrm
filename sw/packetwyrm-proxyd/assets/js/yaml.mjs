/* Test-config YAML emitter: form model -> plain object -> YAML via the vendored
 * js-yaml (window.jsyaml.dump). Building an object and letting the library
 * serialise removes hand-rolled quoting/escaping: MAC/IPv6 colons, names with
 * YAML-special chars, etc. are quoted correctly by construction, and the emit
 * side now uses the SAME library as the parse side (validateYaml). */
import { state } from "./state.mjs";

/* Scalar coercion: plain decimal -> Number (clean unquoted YAML int); hex
 * (0x..), addresses, names, modes -> string (js-yaml quotes when needed, and
 * the daemon's u16/u32/u64 parsers accept the quoted text incl. 0x hex). */
function scalar(v) {
  if (typeof v === "number" || typeof v === "boolean") return v;
  const s = String(v);
  return /^-?\d+$/.test(s) ? parseInt(s, 10) : s;
}
const setv = v => v !== "" && v != null;

/* One flow's form model -> plain object mirroring the YAML schema. */
export function flowObj(f) {
  const raw = f.frame_template && f.frame_template !== "test";
  const o = { id: scalar(f.id) };
  if (f.name) o.name = String(f.name);
  o.tx_global_port = scalar(f.tx);
  o.rx_global_port = scalar(f.rx);

  const l2 = { src_mac: String(f.src_mac), dst_mac: String(f.dst_mac) };
  if (setv(f.vlan)) l2.vlan = scalar(f.vlan);
  if (setv(f.ethertype)) l2.ethertype = scalar(f.ethertype);
  o.l2 = l2;

  const ip = { src: String(f.ip_src), dst: String(f.ip_dst) };
  if (f.l3 === "ipv6") { if (f.ttl) ip.hop_limit = scalar(f.ttl); o.ipv6 = ip; }
  else                 { if (f.ttl) ip.ttl = scalar(f.ttl);       o.ipv4 = ip; }

  const l4 = { src_port: scalar(f.sport), dst_port: scalar(f.dport) };
  if (f.l4 === "tcp" && f.tcp_flags) l4.flags = scalar(f.tcp_flags);
  o[f.l4] = l4;   // "udp" or "tcp"

  const tr = { frame_len: scalar(f.frame_len) };
  tr[f.rate_mode === "pps" ? "rate_pps" : "rate_bps"] = scalar(f.rate);
  tr.payload = String(f.payload);
  tr.insert_sequence = !!f.seq;
  tr.insert_timestamp = !!f.ts;
  if (raw) tr.frame_template = String(f.frame_template);
  o.traffic = tr;

  // Raw templates carry no test header: no measurements, RX classifies on
  // header fields (the daemon validator enforces this).
  if (!raw) o.measurements = { loss: !!f.m_loss, latency: !!f.m_lat, jitter: !!f.m_jit };
  if (raw) o.classify = "header";
  else if (f.classify && f.classify !== "map") o.classify = String(f.classify);
  if (f.background) o.background = true;

  const m = f.match || {}, mo = {};
  if (setv(m.udp_dst))         mo.udp_dst = scalar(m.udp_dst);
  if (setv(m.ipv4_dst))        mo.ipv4_dst = scalar(m.ipv4_dst);
  if (setv(m.ipv6_dst_prefix)) mo.ipv6_dst_prefix = scalar(m.ipv6_dst_prefix);
  if (setv(m.ipv6_src_prefix)) mo.ipv6_src_prefix = scalar(m.ipv6_src_prefix);
  if (Object.keys(mo).length) o.match = mo;

  const mods = f.mods || {}, mdo = {};
  for (const k of Object.keys(mods)) {
    const md = mods[k];
    if (!md || !md.mode || md.mode === "static") continue;
    const e = { mode: String(md.mode) };
    if (setv(md.mask)) e.mask = scalar(md.mask);
    mdo[k] = e;
  }
  if (Object.keys(mdo).length) o.modifiers = mdo;

  const e = f.encap || {};
  if (e.type && e.type !== "none") {
    const fam = e.l3 === "ipv6" ? "ipv6" : "ipv4";
    const inner = { src: String(e.src), dst: String(e.dst) };
    if (setv(e.ttl))  inner[fam === "ipv6" ? "hop_limit" : "ttl"] = scalar(e.ttl);
    if (setv(e.dscp)) inner.dscp = scalar(e.dscp);
    const enc = { type: String(e.type), outer: { [fam]: inner } };
    if (e.type === "etherip" && (e.inner_src_mac || e.inner_dst_mac))
      enc.inner_l2 = { src_mac: String(e.inner_src_mac || ""), dst_mac: String(e.inner_dst_mac || "") };
    o.encap = enc;
    if (f.rx_expect && f.rx_expect !== "inner") o.rx_expect = String(f.rx_expect);
  }
  return o;
}

/* One forward rule's form model -> plain object. */
export function fwdObj(r) {
  const o = { ingress_port: scalar(r.ingress), egress_port: scalar(r.egress) };
  if (r.name) o.name = String(r.name);
  if (setv(r.priority)) o.priority = scalar(r.priority);
  for (const k of ["ethertype", "ip_proto", "udp_dst", "vlan"])
    if (setv(r[k])) o[k] = scalar(r[k]);
  for (const k of ["ipv6_dst", "ipv6_src"]) if (r[k]) o[k] = String(r[k]);
  return o;
}

/* Serialise an object to YAML via js-yaml. lineWidth:-1 keeps long
 * addresses/hex on one line; noRefs avoids anchors/aliases. */
function dumpYaml(obj) {
  const j = (typeof window !== "undefined") ? window.jsyaml : undefined;
  if (!j || !j.dump) throw new Error("js-yaml (window.jsyaml) not loaded");
  return j.dump(obj, { lineWidth: -1, noRefs: true, quotingType: '"' });
}

/* A single flow as a `flows:`-rooted YAML doc (used by the frame preview). */
export function flowYaml(f) { return dumpYaml({ flows: [flowObj(f)] }); }
/* A single forward rule as a `forwards:`-rooted YAML doc. */
export function fwdYaml(r) { return dumpYaml({ forwards: [fwdObj(r)] }); }

/* The full test config (flows + forwards) the "Write to card" / raw editor use. */
export function buildTestYaml() {
  const doc = {};
  if (state.flows.length) doc.flows = state.flows.map(flowObj);
  if (state.fwds.length)  doc.forwards = state.fwds.map(fwdObj);
  if (!doc.flows && !doc.forwards) doc.flows = [];
  return dumpYaml(doc);
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
