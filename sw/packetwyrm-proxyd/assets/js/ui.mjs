/* Shared UI widgets. (Phase 1 will add toast/confirm/async-button helpers here.) */
import { el } from "./dom.mjs";

export function statePill(on) {
  return el("span", { class: on ? "pill on" : "pill off", text: on ? "Started" : "Stopped" });
}
