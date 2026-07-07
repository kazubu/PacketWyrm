/* Transport: control-socket RPC relay + connection status + inline messages.
 * The control secret lives in sessionStorage (per-tab, cleared on close) rather
 * than localStorage -- it survives a reload within the session but doesn't
 * linger on disk to widen the blast radius of a future XSS. Migrate away from
 * (and clear) any previously-persisted localStorage copy. */
import { $ } from "./dom.mjs";

try { localStorage.removeItem("pw_secret"); } catch (_) {}

export function initSecret() {
  $("#secret").value = sessionStorage.getItem("pw_secret") || "";
  $("#secret").addEventListener("change",
    e => sessionStorage.setItem("pw_secret", e.target.value));
}

export function setConn(ok, txt) {
  const c = $("#conn"); c.className = ok ? "ok" : "err"; c.textContent = txt;
}

export async function rpc(obj) {
  const s = $("#secret").value;
  const body = s ? { ...obj, secret: s } : obj;
  // X-PW-Request is required by proxyd (CSRF defence: forces a CORS
  // preflight for cross-origin pages, which proxyd never answers).
  const r = await fetch("/api/rpc", { method: "POST",
    headers: { "Content-Type": "application/json", "X-PW-Request": "1" },
    body: JSON.stringify(body) });
  const j = await r.json();
  if (j && j.error === "unauthorized") { setConn(false, "unauthorized"); }
  else setConn(true, "connected");
  return j;
}

export function showMsg(id, kind, text) {
  const m = $(id); m.className = "msg " + kind; m.textContent = text;
}
