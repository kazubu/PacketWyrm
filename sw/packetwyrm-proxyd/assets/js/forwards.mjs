/* Forwards (store-and-forward rule) list + editor. */
import { $, el } from "./dom.mjs";
import { rpc, showMsg } from "./rpc.mjs";
import { state, newFwd } from "./state.mjs";
import { buildTestYaml } from "./yaml.mjs";

export function renderFwdList() {
  const box = $("#fwd-list"); box.innerHTML = "";
  if (!state.fwds.length) { box.append(el("div", { class: "muted", text: "No rules." })); return; }
  const t = el("table"); t.append(el("tr", {}, [el("th", { text: "name" }), el("th", { text: "in→out" }),
    el("th", { text: "prio" }), el("th", { text: "" })]));
  state.fwds.forEach((r, i) => t.append(el("tr", {}, [el("td", { text: r.name || "—" }),
    el("td", { text: `${r.ingress}→${r.egress}` }), el("td", { text: r.priority }),
    el("td", {}, [el("button", { class: "ghost", text: "edit", onclick: () => { state.selFwd = i; renderFwdEdit(); } }), " ",
      el("button", { class: "danger", text: "del", onclick: () => { state.fwds.splice(i, 1); state.selFwd = null; renderFwdList(); renderFwdEdit(); $("#flow-yaml").value = buildTestYaml(); } })])])));
  box.append(t);
}

export function renderFwdEdit() {
  const box = $("#fwd-edit"); box.innerHTML = "";
  if (state.selFwd == null || !state.fwds[state.selFwd]) { box.className = "muted"; box.textContent = "Add a rule to edit."; return; }
  box.className = "";
  const r = state.fwds[state.selFwd];
  const fld = (label, key, type = "text") => {
    const inp = el("input", { type, value: r[key] });
    inp.addEventListener("change", e => { let v = e.target.value; if (type === "number") v = v === "" ? "" : Number(v); r[key] = v; renderFwdList(); $("#flow-yaml").value = buildTestYaml(); });
    return el("div", {}, [el("label", { text: label }), inp]);
  };
  box.append(el("div", { class: "grid" }, [
    fld("name", "name"), fld("ingress_port", "ingress", "number"), fld("egress_port", "egress", "number"),
    fld("priority", "priority", "number"), fld("ethertype (hex/dec)", "ethertype"),
    fld("ip_proto", "ip_proto", "number"), fld("udp_dst", "udp_dst", "number"),
    fld("vlan", "vlan", "number"), fld("ipv6_dst (addr[/prefix])", "ipv6_dst"),
    fld("ipv6_src (addr[/prefix])", "ipv6_src")]));
}

export function initForwards() {
  $("#fwd-add").addEventListener("click", () => { state.fwds.push(newFwd()); state.selFwd = state.fwds.length - 1; renderFwdList(); renderFwdEdit(); $("#flow-yaml").value = buildTestYaml(); });
  $("#fwd-apply").addEventListener("click", async () => {
    const r = await rpc({ rpc: "config.load", yaml: buildTestYaml() });
    if (r.ok) showMsg("#fwd-msg", "ok", `Loaded: ${r.n_flows} flows, ${r.n_classifier_rows} classifier rows`);
    else showMsg("#fwd-msg", "err", r.error || JSON.stringify(r));
  });
}
