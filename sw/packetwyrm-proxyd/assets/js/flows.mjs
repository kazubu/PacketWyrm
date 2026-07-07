/* Test-flow list + form editor. */
import { $, el } from "./dom.mjs";
import { rpc, showMsg } from "./rpc.mjs";
import { confirmDialog, withPending } from "./ui.mjs";
import { state, newFlow, flowFromJson, fwdFromJson, MOD_FIELDS } from "./state.mjs";
import { buildTestYaml } from "./yaml.mjs";
import { renderFwdList, renderFwdEdit } from "./forwards.mjs";

function renderFlowList() {
  const box = $("#flow-list");
  box.innerHTML = "";
  if (!state.flows.length) { box.append(el("div", { class: "muted", text: "No flows. Add one." })); return; }
  const t = el("table"); t.append(el("tr", {}, [
    el("th", { text: "id" }), el("th", { text: "name" }), el("th", { text: "tx→rx" }),
    el("th", { text: "L3/L4" }), el("th", { text: "rate" }), el("th", { text: "" })]));
  state.flows.forEach((f, i) => {
    t.append(el("tr", {}, [
      el("td", { text: f.id }), el("td", { text: f.name || "—" }),
      el("td", { text: `${f.tx}→${f.rx}` }), el("td", { text: `${f.l3}/${f.l4}` }),
      el("td", { text: `${f.rate} ${f.rate_mode || "bps"}` }),
      el("td", {}, [
        el("button", { class: "ghost", text: "edit", onclick: () => { state.selFlow = i; renderFlowEdit(); } }),
        " ",
        el("button", { class: "danger", text: "del", onclick: async () => {
          if (!await confirmDialog(`Delete flow ${f.id}${f.name ? ` (${f.name})` : ""}?`, { ok: "Delete", danger: true })) return;
          state.flows.splice(i, 1); state.selFlow = null; refreshFlows(); } })
      ])]));
  });
  box.append(t);
}

function field(label, obj, key, type = "text", opts = null) {
  const id = "fe_" + key;
  let input;
  if (type === "select") {
    input = el("select", { id });
    opts.forEach(o => input.append(el("option", { value: o, text: o, ...(obj[key] == o ? { selected: "1" } : {}) })));
  } else if (type === "checkbox") {
    input = el("input", { type: "checkbox", id }); input.checked = !!obj[key];
  } else {
    input = el("input", { type, id, value: obj[key] });
  }
  input.addEventListener("change", e => {
    let v = type === "checkbox" ? e.target.checked : e.target.value;
    if (type === "number") v = v === "" ? "" : Number(v);
    obj[key] = v; refreshFlows(false);
  });
  if (type === "checkbox") return el("div", { class: "chk" }, [input, el("span", { text: label })]);
  return el("div", {}, [el("label", { text: label }), input]);
}

function renderFlowEdit() {
  const box = $("#flow-edit");
  box.innerHTML = "";
  if (state.selFlow == null || !state.flows[state.selFlow]) { box.className = "muted"; box.textContent = "Add or select a flow to edit."; return; }
  box.className = "";
  const f = state.flows[state.selFlow];
  box.append(el("div", { class: "grid" }, [
    field("id (int)", f, "id", "number"), field("name", f, "name"),
    field("tx port", f, "tx", "number"), field("rx port", f, "rx", "number"),
    field("src MAC", f, "src_mac"), field("dst MAC", f, "dst_mac"),
    field("vlan (blank=none)", f, "vlan", "number"),
    field("ethertype (eth tmpl, blank=auto)", f, "ethertype"),
    field("L3", f, "l3", "select", ["ipv4", "ipv6"]),
    field("ip src", f, "ip_src"), field("ip dst", f, "ip_dst"),
    field("ttl / hop_limit", f, "ttl", "number"),
    field("L4", f, "l4", "select", ["udp", "tcp"]),
    field("src port", f, "sport", "number"), field("dst port", f, "dport", "number"),
    field("tcp flags (hex, tcp only)", f, "tcp_flags"),
    field("frame_len", f, "frame_len", "number"),
    field("rate mode", f, "rate_mode", "select", ["bps", "pps"]), field("rate", f, "rate", "number"),
    field("payload", f, "payload", "select", ["zero", "increment", "prbs", "random"]),
    field("frame_template", f, "frame_template", "select", ["test", "raw", "ip", "eth"]),
    field("classify", f, "classify", "select", ["map", "header"]),
  ]));
  box.append(el("div", { class: "row", style: "margin-top:8px" }, [
    field("insert_sequence", f, "seq", "checkbox"), field("insert_timestamp", f, "ts", "checkbox"),
    field("meas loss", f, "m_loss", "checkbox"), field("meas latency", f, "m_lat", "checkbox"),
    field("meas jitter", f, "m_jit", "checkbox"), field("background (TX-only)", f, "background", "checkbox"),
  ]));

  // --- advanced: match (classifier masks) ---
  const det = (title, kids, open = false) => {
    const d = el("details", open ? { open: "1" } : {});
    d.append(el("summary", { text: title }));
    [].concat(kids).forEach(k => d.append(k));
    return d;
  };
  box.append(det("match — partial-field classifier masks (classify: header)", [
    el("p", { class: "muted", text: "Blank = exact match. Masks are hex (e.g. 0xff00); prefixes are lengths." }),
    el("div", { class: "grid" }, [
      field("udp_dst mask", f.match, "udp_dst"),
      field("ipv4_dst mask", f.match, "ipv4_dst"),
      field("ipv6_dst_prefix", f.match, "ipv6_dst_prefix", "number"),
      field("ipv6_src_prefix", f.match, "ipv6_src_prefix", "number"),
    ])]));

  // --- advanced: modifiers (per-field variation) ---
  const modRows = MOD_FIELDS.map(k => el("div", { class: "row", style: "gap:8px" }, [
    el("div", { style: "width:80px;color:var(--dim);font-size:12px", text: k }),
    (() => { const w = field("", f.mods[k], "mode", "select", ["static", "increment", "random"]);
             w.style.flex = "0 0 140px"; return w; })(),
    (() => { const w = field("mask (hex, or IPv6 literal for v6)", f.mods[k], "mask");
             w.style.flex = "1"; return w; })(),
  ]));
  box.append(det("modifiers — per-packet field variation", [
    el("p", { class: "muted", text: "mode=static leaves the field fixed. mask picks which bits vary." }),
    ...modRows]));

  // --- advanced: encap (tunnel) ---
  box.append(det("encap — tunnel the test frame (IPIP / GRE / EtherIP)", [
    el("div", { class: "grid" }, [
      field("type", f.encap, "type", "select", ["none", "ipip", "gre", "etherip"]),
      field("outer L3", f.encap, "l3", "select", ["ipv4", "ipv6"]),
      field("outer src", f.encap, "src"), field("outer dst", f.encap, "dst"),
      field("outer ttl / hop_limit", f.encap, "ttl", "number"),
      field("outer dscp", f.encap, "dscp", "number"),
      field("inner src MAC (etherip)", f.encap, "inner_src_mac"),
      field("inner dst MAC (etherip)", f.encap, "inner_dst_mac"),
      field("rx_expect", f, "rx_expect", "select", ["inner", "tunneled"]),
    ])]));
}

export function refreshFlows(reEdit = true) {
  renderFlowList();
  if (reEdit) renderFlowEdit();
  $("#flow-yaml").value = buildTestYaml();
}

export function initFlows() {
  $("#flow-add").addEventListener("click", () => { state.flows.push(newFlow()); state.selFlow = state.flows.length - 1; refreshFlows(); });
  $("#flow-load").addEventListener("click", e => withPending(e.currentTarget, async () => {
    const r = await rpc({ rpc: "config.get_test" });
    if (r.error) { showMsg("#flow-msg", "err", r.error); return; }
    const jf = Array.isArray(r.flows) ? r.flows : [];
    const jw = Array.isArray(r.forwards) ? r.forwards : [];
    const hasForm = jf.length || jw.length;
    const hasYaml = r.yaml && r.yaml.trim();
    if (!hasForm && !hasYaml) {
      showMsg("#flow-msg", "warn", "No test config loaded yet (load one via Apply, "
        + "`pktwyrm load`, or the daemon's -t). Nothing to edit.");
      return;
    }
    // Populate the form model from the structured flows/forwards…
    if (hasForm) {
      state.flows = jf.map(flowFromJson);
      state.fwds = jw.map(fwdFromJson);
      state.selFlow = state.flows.length ? 0 : null;
      state.selFwd = state.fwds.length ? 0 : null;
      refreshFlows();            // rebuilds list + editor + regenerates YAML preview
      renderFwdList(); renderFwdEdit();
    }
    // …and the raw editor with the lossless original text when we have it.
    if (hasYaml) $("#flow-yaml").value = r.yaml;
    $("#flow-yaml-details").open = true;
    showMsg("#flow-msg", "ok",
      `Loaded ${state.flows.length} flow(s)${state.fwds.length ? ` + ${state.fwds.length} forward(s)` : ""} `
      + "into the form and the YAML editor. Edit above, then Apply.");
  }));
  $("#flow-apply").addEventListener("click", e => withPending(e.currentTarget, async () => {
    if (!await confirmDialog("Apply this config? It replaces the running test config on the FPGA.", { ok: "Apply" })) return;
    const yaml = buildTestYaml();
    $("#flow-yaml").value = yaml;
    const r = await rpc({ rpc: "config.load", yaml });
    if (r.ok) showMsg("#flow-msg", "ok", `Loaded: ${r.n_flows} flows, ${r.n_classifier_rows} classifier rows`);
    else showMsg("#flow-msg", "err", r.error || JSON.stringify(r));
  }));
  $("#flow-apply-raw").addEventListener("click", e => withPending(e.currentTarget, async () => {
    if (!await confirmDialog("Apply the raw YAML? It replaces the running test config on the FPGA.", { ok: "Apply raw" })) return;
    const r = await rpc({ rpc: "config.load", yaml: $("#flow-yaml").value });
    if (r.ok) showMsg("#flow-msg", "ok", `Loaded (raw): ${r.n_flows} flows, ${r.n_classifier_rows} classifier rows`);
    else showMsg("#flow-msg", "err", r.error || JSON.stringify(r));
  }));
}
