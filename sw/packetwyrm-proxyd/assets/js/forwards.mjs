/* Forwards (store-and-forward rules) list — same UX as Flows: each rule is an
 * expandable single-open accordion row whose editor opens inline, edits are
 * STAGED in a per-rule working copy ("Apply edit" commits into the config + YAML
 * preview, "Revert" discards, "● modified" badge). "Write to card" (shared with
 * the Flows tab) programs the committed config onto the FPGA. */
import { $, $$, el } from "./dom.mjs";
import { showMsg } from "./rpc.mjs";
import { confirmDialog, withPending } from "./ui.mjs";
import { state, newFwd } from "./state.mjs";
import { buildTestYaml, fwdFieldError, fwdErrors } from "./yaml.mjs";
import { clone, workingFor, peekWorking, modified, dropWorking, isRawDirty } from "./staging.mjs";
import { writeToCard } from "./flows.mjs";

const fwdSummary = r =>
  `${r.name || "(no name)"} · ${r.ingress}→${r.egress} · prio ${r.priority}`;

// Update row summaries (from the staged working copy), modified badges, and each
// editor's Apply/Revert enabled state — WITHOUT rebuilding the list.
function refreshFwdRows() {
  $$("#fwd-list details.flow-item").forEach((d, i) => {
    const r = state.fwds[i]; if (!r) return;
    const w = peekWorking(r) || r;
    const mod = modified(r);
    const sum = d.querySelector(".flow-sum"); if (sum) sum.textContent = fwdSummary(w);
    const badge = d.querySelector(".flow-mod"); if (badge) badge.textContent = mod ? "● modified" : "";
    const ap = d.querySelector(".ed-apply"); if (ap) ap.disabled = !mod;
    const rv = d.querySelector(".ed-revert"); if (rv) rv.disabled = !mod;
  });
}

function fld(label, obj, key, type = "text") {
  const input = el("input", { type, value: obj[key] });
  input.addEventListener("change", e => {
    let v = e.target.value; if (type === "number") v = v === "" ? "" : Number(v);
    obj[key] = v;
    input.classList.toggle("invalid", !!fwdFieldError(key, v));
    refreshFwdRows();
  });
  input.classList.toggle("invalid", !!fwdFieldError(key, obj[key]));
  return el("div", {}, [el("label", { text: label }), input]);
}

function buildFwdEditor(box, r) {
  const w = workingFor(r);
  box.append(el("div", { class: "grid" }, [
    fld("name", w, "name"), fld("ingress_port", w, "ingress", "number"), fld("egress_port", w, "egress", "number"),
    fld("priority", w, "priority", "number"), fld("ethertype (hex/dec)", w, "ethertype"),
    fld("ip_proto", w, "ip_proto", "number"), fld("udp_dst", w, "udp_dst", "number"),
    fld("vlan", w, "vlan", "number"), fld("ipv6_dst (addr[/prefix])", w, "ipv6_dst"),
    fld("ipv6_src (addr[/prefix])", w, "ipv6_src"),
  ]));
  const applyBtn = el("button", { class: "act ed-apply", text: "Apply edit",
    title: "Commit these edits into the config / YAML preview (does NOT write to the card)" });
  const revertBtn = el("button", { class: "act ghost ed-revert", text: "Revert",
    title: "Discard the edits and restore the committed values" });
  applyBtn.disabled = revertBtn.disabled = !modified(r);
  applyBtn.addEventListener("click", () => {
    const errs = fwdErrors(w);   // don't commit invalid fields (mirror Flows)
    if (errs.length) { showMsg("#fwd-msg", "err", "Fix these first:\n• " + errs.join("\n• ")); return; }
    const idx = state.fwds.indexOf(r);
    if (idx >= 0) { state.fwds[idx] = clone(w); state.selFwd = idx; }
    if (!isRawDirty()) $("#flow-yaml").value = buildTestYaml();
    refreshFwds();
    showMsg("#fwd-msg", "ok", `Rule ${w.name || `${w.ingress}→${w.egress}`} committed. Use “Write to card” to program the FPGA.`);
  });
  revertBtn.addEventListener("click", () => { dropWorking(r); refreshFwds(); });
  box.append(el("div", { class: "row flow-actions" }, [applyBtn, revertBtn]));
}

export function renderFwdList() {
  const box = $("#fwd-list"); box.innerHTML = "";
  if (!state.fwds.length) { box.append(el("div", { class: "muted", text: "No rules. Add one." })); return; }
  state.fwds.forEach((r, i) => {
    const open = state.selFwd === i;
    const w = peekWorking(r) || r;
    const det = el("details", { class: "flow-item", ...(open ? { open: "1" } : {}) });
    const del = el("button", { class: "danger", text: "del", "aria-label": `delete rule ${r.name || i}` });
    del.addEventListener("click", async (e) => {
      e.preventDefault(); e.stopPropagation();
      if (!await confirmDialog(`Delete forward rule ${r.name || `${r.ingress}→${r.egress}`}?`, { ok: "Delete", danger: true })) return;
      dropWorking(r);
      const idx = state.fwds.indexOf(r); if (idx >= 0) state.fwds.splice(idx, 1);
      state.selFwd = null; refreshFwds();
    });
    det.append(el("summary", {}, [
      el("span", { class: "flow-sum", text: fwdSummary(w) }),
      el("span", { class: "flow-mod", text: modified(r) ? "● modified" : "" }),
      del,
    ]));
    const body = el("div", { class: "flow-editor" });
    det.append(body);
    const build = () => { if (!body.dataset.built) { buildFwdEditor(body, r); body.dataset.built = "1"; } };
    if (open) build();
    det.addEventListener("toggle", () => {
      if (!det.open) return;
      state.selFwd = i;
      build();
      $$("#fwd-list details.flow-item").forEach(d => { if (d !== det) d.open = false; });
    });
    box.append(det);
  });
}

// Rebuild the list + refresh the shared YAML preview (unless the raw editor is dirty).
export function refreshFwds() {
  renderFwdList();
  if (!isRawDirty()) $("#flow-yaml").value = buildTestYaml();
}

export function initForwards() {
  $("#fwd-add").addEventListener("click", () => { state.fwds.push(newFwd()); state.selFwd = state.fwds.length - 1; refreshFwds(); });
  $("#fwd-apply").addEventListener("click", e => withPending(e.currentTarget, () => writeToCard("#fwd-msg")));
}
