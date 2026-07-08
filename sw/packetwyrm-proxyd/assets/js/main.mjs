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
  $$("nav button").forEach(x => {
    const on = x === b;
    x.classList.toggle("active", on);
    x.setAttribute("aria-selected", on ? "true" : "false");   // ARIA tablist state
  });
  $$(".tab").forEach(t => t.classList.remove("active"));
  $("#tab-" + b.dataset.tab).classList.add("active");
  if (b.dataset.tab === "control") renderCtlFlows();
}));

/* ---- theme (dark default; light opt-in, persisted) ---- */
function applyTheme(t) {
  if (t === "light") document.documentElement.setAttribute("data-theme", "light");
  else document.documentElement.removeAttribute("data-theme");
}
try { if (localStorage.getItem("pw_theme") === "light") applyTheme("light"); } catch (_) {}
$("#theme").addEventListener("click", () => {
  const next = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
  applyTheme(next);
  try { localStorage.setItem("pw_theme", next); } catch (_) {}
});

/* ---- boot ---- */
initSecret();
initFlows();
initForwards();
initControl();
initDashboard();
initEnv();

state.flows = [newFlow()]; refreshFlows();
renderFwdList(); renderFwdEdit();
$("#conn").textContent = "connecting…";   // neutral until the first poll resolves
poll(); setInterval(poll, 1500);
