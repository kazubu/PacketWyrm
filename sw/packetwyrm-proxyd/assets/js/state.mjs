/* Shared config model (flows / forwards) + selection + session health memory.
 * Kept in a single `state` object so modules can reassign state.flows etc.
 * across module boundaries (ES-module import bindings can't be reassigned). */

export const state = { flows: [], fwds: [], selFlow: null, selFwd: null };

export const MOD_FIELDS = ["src_ipv4", "dst_ipv4", "src_ipv6", "dst_ipv6",
                           "udp_src", "udp_dst", "src_mac", "dst_mac", "vlan"];
export const newMods = () => Object.fromEntries(MOD_FIELDS.map(k => [k, { mode: "static", mask: "" }]));

export const newFlow = () => ({
  id: (state.flows.reduce((m, f) => Math.max(m, f.id), 0) || 0) + 1, name: "",
  tx: 0, rx: 1, src_mac: "02:a5:02:00:00:01", dst_mac: "02:a5:02:00:00:02", vlan: "", ethertype: "",
  l3: "ipv4", ip_src: "192.0.2.1", ip_dst: "192.0.2.2", ttl: 64,
  l4: "udp", sport: 49152, dport: 50001, tcp_flags: "",
  frame_len: 512, rate_mode: "bps", rate: 1000000000, payload: "increment",
  frame_template: "test", seq: true, ts: true,
  m_loss: true, m_lat: true, m_jit: true, classify: "map", background: false,
  // advanced (optional)
  match: { udp_dst: "", ipv4_dst: "", ipv6_dst_prefix: "", ipv6_src_prefix: "" },
  mods: newMods(),
  encap: { type: "none", l3: "ipv4", src: "", dst: "", ttl: "", dscp: "",
           inner_src_mac: "", inner_dst_mac: "" },
  rx_expect: "inner" });

// Map a config.get_test flow object (daemon form-model JSON) onto a full flow
// model, filling any missing field/section from the defaults.
export function flowFromJson(j) {
  const f = newFlow();
  Object.assign(f, j);
  f.match = Object.assign({ udp_dst: "", ipv4_dst: "", ipv6_dst_prefix: "", ipv6_src_prefix: "" }, j.match || {});
  f.mods = newMods();
  if (j.mods) for (const k of MOD_FIELDS)
    if (j.mods[k]) f.mods[k] = Object.assign({ mode: "static", mask: "" }, j.mods[k]);
  f.encap = Object.assign({ type: "none", l3: "ipv4", src: "", dst: "", ttl: "", dscp: "",
                            inner_src_mac: "", inner_dst_mac: "" }, j.encap || {});
  return f;
}

export const newFwd = () => ({ name: "", ingress: 0, egress: 1, priority: 40,
  ethertype: "", ip_proto: "", udp_dst: "", vlan: "", ipv6_dst: "", ipv6_src: "" });
export const fwdFromJson = (j) => Object.assign(newFwd(), j);

// Cards where this dashboard session has observed an error at least once (the
// physical LED's err_sticky latches until stats.clear; we approximate it here).
export const healthSeenErr = new Set();
