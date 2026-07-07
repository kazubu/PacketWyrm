/* Control tab: test orchestration + per-flow start/stop. */
import { $, $$, el } from "./dom.mjs";
import { rpc, showMsg } from "./rpc.mjs";
import { statePill } from "./ui.mjs";
import { healthSeenErr } from "./state.mjs";
import { poll } from "./dashboard.mjs";

export async function renderCtlFlows() {
  const box = $("#ctl-flows"); box.textContent = "…";
  const r = await rpc({ rpc: "flows" });
  box.innerHTML = "";
  const list = (r && r.flows) || [];
  if (!list.length) { box.append(el("div", { class: "muted", text: "No flows programmed. Apply a config first." })); return; }
  const t = el("table"); t.append(el("tr", {}, [el("th", { text: "id" }), el("th", { text: "name" }),
    el("th", { text: "tx→rx" }), el("th", { text: "state" }), el("th", { text: "" })]));
  list.forEach(f => {
    const on = !!f.enabled;
    // Button reflects current state: shows the action that flips it.
    const btn = el("button", { class: on ? "danger" : "start", text: on ? "Stop" : "Start",
      onclick: async () => { await rpc({ rpc: on ? "flow.stop" : "flow.start", id: f.id }); renderCtlFlows(); } });
    t.append(el("tr", {}, [el("td", { text: f.id }), el("td", { text: f.name || "—" }),
      el("td", { text: `${f.tx_global_port}→${f.rx_global_port}` }),
      el("td", {}, [statePill(on)]), el("td", {}, [btn])]));
  });
  box.append(t);
}

export function initControl() {
  $$("[data-rpc]").forEach(b => b.addEventListener("click", async () => {
    const r = await rpc({ rpc: b.dataset.rpc });
    showMsg("#ctl-msg", r.error ? "err" : "ok", JSON.stringify(r));
    // stats.clear resets the FPGA err_sticky (LED) + counters, so drop the
    // session's "error seen earlier" memory too, else the health stays amber.
    if (b.dataset.rpc === "stats.clear" && !r.error) healthSeenErr.clear();
    // test.arm/start/stop change every flow's enable -> refresh the per-flow table;
    // poll() refreshes the dashboard health/stats after any action.
    renderCtlFlows();
    poll();
  }));
}
