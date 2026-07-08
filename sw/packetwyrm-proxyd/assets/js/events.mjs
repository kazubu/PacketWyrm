/* Event timeline ("WHEN did it break"): a client-side, session-local log. The
 * dashboard poll diffs error counters (per-flow lost/dup/reorder/seq-gap,
 * per-port FCS/drops) and appends a timestamped entry per positive delta;
 * Control-tab actions (arm/start/stop/clear, per-flow start/stop) log too.
 * Ring buffer of the last 200 entries, newest first. No daemon support needed. */
import { $, el } from "./dom.mjs";

const MAX = 200;
const events = [];   // {t, text, kind: "info"|"bad"|"act"} -- newest first

const ts = () => {
  const d = new Date(), p = n => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};

// One poll can log a burst of deltas; coalesce renders into a single microtask.
let renderQueued = false;
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  queueMicrotask(() => { renderQueued = false; render(); });
}

function render() {
  const box = $("#d-events"); if (!box) return;
  box.innerHTML = "";
  if (!events.length) {
    box.append(el("div", { class: "muted",
      text: "No events yet. Error-counter increases and GUI test actions appear here with a timestamp." }));
    return;
  }
  events.forEach(ev => box.append(el("div", { class: "evt " + ev.kind }, [
    el("span", { class: "evt-t", text: ev.t }),
    el("span", { text: ev.text })])));
}

export function logEvent(text, kind = "info") {
  events.unshift({ t: ts(), text, kind });
  if (events.length > MAX) events.length = MAX;
  scheduleRender();
}

export function initEvents() {
  $("#ev-clear").addEventListener("click", () => { events.length = 0; render(); });
  render();
}
