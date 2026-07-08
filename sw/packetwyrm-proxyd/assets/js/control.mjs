/* Control tab: test orchestration + per-flow start/stop. Each orchestration
 * button carries a small copy-CLI affordance (the equivalent pktwyrm command),
 * and every action performed here is logged to the Events timeline. */
import { $, $$, el } from "./dom.mjs";
import { rpc } from "./rpc.mjs";
import { statePill, toast, confirmDialog, withPending, copyText, cliBase } from "./ui.mjs";
import { healthSeenErr } from "./state.mjs";
import { logEvent } from "./events.mjs";
import { poll } from "./dashboard.mjs";

// data-rpc name -> the equivalent pktwyrm subcommand (for the copy-CLI button)
const CLI_FOR = { "test.arm": "test arm", "test.start": "test start",
                  "test.stop": "test stop", "stats.clear": "stats clear" };

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
      onclick: () => withPending(btn, async () => {
        const name = on ? "flow.stop" : "flow.start";
        const r2 = await rpc({ rpc: name, id: f.id });
        if (r2 && r2.error) { toast("err", `flow ${f.id}: ${r2.error}`); logEvent(`GUI: ${name} ${f.id} failed: ${r2.error}`, "bad"); }
        else logEvent(`GUI: ${name} ${f.id}`, "act");
        await renderCtlFlows();
      }) });
    t.append(el("tr", {}, [el("td", { text: f.id }), el("td", { text: f.name || "—" }),
      el("td", { text: `${f.tx_global_port}→${f.rx_global_port}` }),
      el("td", {}, [statePill(on)]), el("td", {}, [btn])]));
  });
  box.append(t);
}

export function initControl() {
  $$("[data-rpc]").forEach(b => {
    // unobtrusive copy-CLI affordance: copies the equivalent pktwyrm command
    const sub = CLI_FOR[b.dataset.rpc];
    if (sub) {
      const cmd = () => `${cliBase()} ${sub}`;
      b.after(el("button", { class: "copy-cli", text: "⧉",
        title: `copy CLI: ${cmd()}`, "aria-label": `copy the equivalent CLI command: ${cmd()}`,
        onclick: () => copyText(cmd(), "copied: " + cmd()) }));
    }
    b.addEventListener("click", () => withPending(b, async () => {
      const name = b.dataset.rpc;
      // Confirm the disruptive "Stop all" (aborts a running test on every flow).
      if (name === "test.stop" &&
          !(await confirmDialog("Stop ALL flows? This aborts the running test on every flow.",
                                { ok: "Stop all", danger: true }))) return;
      const r = await rpc({ rpc: name });
      if (r && r.error) { toast("err", `${name}: ${r.error}`); logEvent(`GUI: ${name} failed: ${r.error}`, "bad"); }
      else { toast("ok", `${name} ok`); logEvent(`GUI: ${name}`, "act"); }
      // stats.clear resets the FPGA err_sticky (LED) + counters, so drop the
      // session's "error seen earlier" memory too, else the health stays amber.
      if (name === "stats.clear" && !(r && r.error)) healthSeenErr.clear();
      // test.arm/start/stop change every flow's enable -> refresh the per-flow table;
      // poll() refreshes the dashboard health/stats after any action.
      renderCtlFlows();
      poll();
    }));
  });
}
