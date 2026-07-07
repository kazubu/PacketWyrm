/* Entry point: tab navigation + boot wiring. */
import { $, $$ } from "./dom.mjs";
import { initSecret } from "./rpc.mjs";
import { state, newFlow } from "./state.mjs";
import { initFlows, refreshFlows } from "./flows.mjs";
import { initForwards, renderFwdList, renderFwdEdit } from "./forwards.mjs";
import { initControl, renderCtlFlows } from "./control.mjs";
import { initDashboard, poll } from "./dashboard.mjs";
import { initEnv } from "./env.mjs";

/* ---- tabs ---- */
$$("nav button").forEach(b => b.addEventListener("click", () => {
  $$("nav button").forEach(x => x.classList.remove("active"));
  b.classList.add("active");
  $$(".tab").forEach(t => t.classList.remove("active"));
  $("#tab-" + b.dataset.tab).classList.add("active");
  if (b.dataset.tab === "control") renderCtlFlows();
}));

/* ---- boot ---- */
initSecret();
initFlows();
initForwards();
initControl();
initDashboard();
initEnv();

state.flows = [newFlow()]; refreshFlows();
renderFwdList(); renderFwdEdit();
poll(); setInterval(poll, 1500);
