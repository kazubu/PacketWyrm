/* Shared UI widgets: state pill, auto-dismissing toasts, a confirm modal, and an
 * async-button helper (disable + spinner while an RPC is in flight). */
import { $, el } from "./dom.mjs";

export function statePill(on) {
  return el("span", { class: on ? "pill on" : "pill off", text: on ? "Started" : "Stopped" });
}

/* ---- toasts: transient, stacked, auto-dismissing action feedback ---- */
function toastHost() {
  let h = $("#toast-host");
  if (!h) { h = el("div", { id: "toast-host" }); document.body.append(h); }
  return h;
}
export function toast(kind, text, ms = 4000) {
  const t = el("div", { class: "toast " + kind, role: "status", text });
  t.addEventListener("click", () => t.remove());   // click to dismiss early
  toastHost().append(t);
  if (ms > 0) setTimeout(() => { t.classList.add("leaving"); setTimeout(() => t.remove(), 200); }, ms);
  return t;
}

/* ---- confirm modal: resolves true (confirmed) / false (cancelled) ---- */
export function confirmDialog(message, { ok = "OK", cancel = "Cancel", danger = false } = {}) {
  return new Promise(resolve => {
    const done = v => { document.removeEventListener("keydown", onKey); overlay.remove(); resolve(v); };
    const onKey = e => { if (e.key === "Escape") done(false); else if (e.key === "Enter") done(true); };
    const okBtn = el("button", { class: "act" + (danger ? " danger" : ""), text: ok, onclick: () => done(true) });
    const cancelBtn = el("button", { class: "act ghost", text: cancel, onclick: () => done(false) });
    const box = el("div", { class: "modal-box", role: "dialog", "aria-modal": "true" }, [
      el("div", { class: "modal-msg", text: message }),
      el("div", { class: "modal-actions" }, [cancelBtn, okBtn]),
    ]);
    const overlay = el("div", { class: "modal-overlay",
      onclick: e => { if (e.target === overlay) done(false); } }, [box]);
    document.body.append(overlay);
    document.addEventListener("keydown", onKey);
    okBtn.focus();
  });
}

/* ---- async-button: disable + spinner while fn() runs; guards double-submit.
 * Uses a CSS class (not textContent) so it's safe even if fn re-renders/replaces
 * the button. Returns fn()'s result (or undefined if a run was already pending). */
export async function withPending(btn, fn) {
  if (btn.dataset.pending) return undefined;
  btn.dataset.pending = "1";
  btn.disabled = true;
  btn.classList.add("pending");
  try { return await fn(); }
  finally {
    // btn may have been detached by a re-render; guard before touching it.
    if (btn.isConnected) { btn.disabled = false; btn.classList.remove("pending"); }
    delete btn.dataset.pending;
  }
}
