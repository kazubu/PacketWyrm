/* Test-flow list: each flow is an expandable row (a <details>) whose editor opens
 * inline (single-open accordion), so it's always clear which flow is being edited.
 *
 * Two-stage editing (per the UX): editing fields is STAGED in a per-flow working
 * copy; the editor's **Apply edit** commits that into the config model + YAML
 * preview (it does NOT touch the card), **Revert** discards it, and a "● modified"
 * badge marks uncommitted edits. The top **Write to card** button (config.load)
 * programs the committed config onto the FPGA. Working copies are keyed by flow
 * OBJECT identity (WeakMap) so they survive collapse/re-render and never leak into
 * the serialised model. The list is only rebuilt on structural changes. */
import { $, $$, el } from "./dom.mjs";
import { rpc, showMsg } from "./rpc.mjs";
import { confirmDialog, withPending, copyText, cliBase } from "./ui.mjs";
import { state, newFlow, flowFromJson, fwdFromJson, MOD_FIELDS } from "./state.mjs";
import { buildTestYaml, flowYaml, validateYaml, fieldError, flowErrors, fwdErrors } from "./yaml.mjs";
import { renderFwdList } from "./forwards.mjs";
import { clone, workingFor, peekWorking, modified, dropWorking, isRawDirty, setRawDirty } from "./staging.mjs";

const flowSummary = f =>
  `#${f.id} · ${f.name || "(no name)"} · ${f.tx}→${f.rx} · ${f.l3}/${f.l4} · ${f.rate} ${f.rate_mode || "bps"}`;

// Engineering-notation with an SI prefix, e.g. 1000000000 bps -> "1 Gbps",
// 1500000 pps -> "1.5 Mpps". Shown next to the raw rate field as a sanity read.
function fmtEng(v, unit) {
  if (!isFinite(v)) return "0 " + unit;
  const neg = v < 0; let a = Math.abs(v);
  const P = ["", "k", "M", "G", "T"]; let i = 0;
  while (a >= 1000 && i < P.length - 1) { a /= 1000; i++; }
  let s = Number.isInteger(a) ? String(a) : a.toFixed(2);
  // rounding can push a value to "1000.00" at a prefix boundary -> step up
  if (parseFloat(s) >= 1000 && i < P.length - 1) { a /= 1000; i++; s = Number.isInteger(a) ? String(a) : a.toFixed(2); }
  return (neg ? "-" : "") + s + " " + P[i] + unit;
}
const rateHintText = w => "= " + fmtEng(Number(w.rate) || 0, w.rate_mode === "pps" ? "pps" : "bps");
// rate field + a live converted-value hint below it
function rateCell(w) {
  const cell = field("rate", w, "rate", "number");
  cell.append(el("div", { class: "rate-hint muted", text: rateHintText(w) }));
  return cell;
}

// Update row summaries (from the staged working copy so edits preview live),
// modified badges, and each editor's Apply/Revert enabled state — WITHOUT
// rebuilding the list (that would collapse the open editor and drop focus).
// Does NOT touch the YAML preview: only an editor "Apply edit" commits to YAML.
function refreshRows() {
  $$("#flow-list details.flow-item").forEach((d, i) => {
    const f = state.flows[i]; if (!f) return;
    const w = peekWorking(f) || f;
    const mod = modified(f);
    const sum = d.querySelector(".flow-sum"); if (sum) sum.textContent = flowSummary(w);
    const badge = d.querySelector(".flow-mod"); if (badge) badge.textContent = mod ? "● modified" : "";
    const ap = d.querySelector(".ed-apply"); if (ap) ap.disabled = !mod;
    const rv = d.querySelector(".ed-revert"); if (rv) rv.disabled = !mod;
    const rh = d.querySelector(".rate-hint"); if (rh) rh.textContent = rateHintText(w);   // live bps/pps conversion
  });
}

function renderFlowList() {
  const box = $("#flow-list");
  box.innerHTML = "";
  if (!state.flows.length) { box.append(el("div", { class: "muted", text: "No flows. Add one." })); return; }
  state.flows.forEach((f, i) => {
    const open = state.selFlow === i;
    const w = peekWorking(f) || f;
    const det = el("details", { class: "flow-item", ...(open ? { open: "1" } : {}) });
    const del = el("button", { class: "danger", text: "del", "aria-label": `delete flow ${f.id}` });
    del.addEventListener("click", async (e) => {
      e.preventDefault(); e.stopPropagation();   // don't toggle the row
      if (!await confirmDialog(`Delete flow ${f.id}${f.name ? ` (${f.name})` : ""}?`, { ok: "Delete", danger: true })) return;
      dropWorking(f);
      const idx = state.flows.indexOf(f); if (idx >= 0) state.flows.splice(idx, 1);   // identity, not render-time i
      state.selFlow = null; refreshFlows();
    });
    det.append(el("summary", {}, [
      el("span", { class: "flow-sum", text: flowSummary(w) }),
      el("span", { class: "flow-mod", text: modified(f) ? "● modified" : "" }),
      del,
    ]));
    const body = el("div", { class: "flow-editor" });
    det.append(body);
    const build = () => { if (!body.dataset.built) { buildFlowEditor(body, f); body.dataset.built = "1"; } };
    if (open) build();   // editor built eagerly for the pre-opened row
    det.addEventListener("toggle", () => {
      if (!det.open) return;
      state.selFlow = i;
      build();
      $$("#flow-list details.flow-item").forEach(d => { if (d !== det) d.open = false; });   // single-open accordion
    });
    box.append(det);
  });
}

function field(label, obj, key, type = "text", opts = null) {
  let input;
  if (type === "select") {
    input = el("select", {});
    opts.forEach(o => input.append(el("option", { value: o, text: o, ...(obj[key] == o ? { selected: "1" } : {}) })));
  } else if (type === "checkbox") {
    input = el("input", { type: "checkbox" }); input.checked = !!obj[key];
  } else {
    input = el("input", { type, value: obj[key] });
  }
  input.addEventListener("change", e => {
    let v = type === "checkbox" ? e.target.checked : e.target.value;
    if (type === "number") v = v === "" ? "" : Number(v);
    obj[key] = v;   // mutate the STAGED working copy (committed only on "Apply edit")
    if (type !== "checkbox" && type !== "select") input.classList.toggle("invalid", !!fieldError(key, v));
    refreshRows();
  });
  if (type !== "checkbox" && type !== "select") input.classList.toggle("invalid", !!fieldError(key, obj[key]));
  if (type === "checkbox") return el("div", { class: "chk" }, [input, el("span", { text: label })]);
  return el("div", {}, [el("label", { text: label }), input]);
}

// Build the staged editor for flow `f` (edits go to its working copy `w`).
function buildFlowEditor(box, f) {
  const w = workingFor(f);
  box.append(el("div", { class: "grid" }, [
    field("id (int)", w, "id", "number"), field("name", w, "name"),
    field("tx port", w, "tx", "number"), field("rx port", w, "rx", "number"),
    field("src MAC", w, "src_mac"), field("dst MAC", w, "dst_mac"),
    field("vlan (blank=none)", w, "vlan", "number"),
    field("ethertype (eth tmpl, blank=auto)", w, "ethertype"),
    field("L3", w, "l3", "select", ["ipv4", "ipv6"]),
    field("ip src", w, "ip_src"), field("ip dst", w, "ip_dst"),
    field("ttl / hop_limit", w, "ttl", "number"),
    field("L4", w, "l4", "select", ["udp", "tcp"]),
    field("src port", w, "sport", "number"), field("dst port", w, "dport", "number"),
    field("tcp flags (hex, tcp only)", w, "tcp_flags"),
    field("frame_len", w, "frame_len", "number"),
    field("rate mode", w, "rate_mode", "select", ["bps", "pps"]), rateCell(w),
    field("payload", w, "payload", "select", ["zero", "increment", "prbs", "random"]),
    field("frame_template", w, "frame_template", "select", ["test", "raw", "ip", "eth"]),
    field("classify", w, "classify", "select", ["map", "header"]),
  ]));
  box.append(el("div", { class: "row", style: "margin-top:8px" }, [
    field("insert_sequence", w, "seq", "checkbox"), field("insert_timestamp", w, "ts", "checkbox"),
    field("meas loss", w, "m_loss", "checkbox"), field("meas latency", w, "m_lat", "checkbox"),
    field("meas jitter", w, "m_jit", "checkbox"), field("background (TX-only)", w, "background", "checkbox"),
  ]));

  const det = (title, kids) => {
    const d = el("details", {});
    d.append(el("summary", { text: title }));
    [].concat(kids).forEach(k => d.append(k));
    return d;
  };
  box.append(det("match — partial-field classifier masks (classify: header)", [
    el("p", { class: "muted", text: "Blank = exact match. Masks are hex (e.g. 0xff00); prefixes are lengths." }),
    el("div", { class: "grid" }, [
      field("udp_dst mask", w.match, "udp_dst"),
      field("ipv4_dst mask", w.match, "ipv4_dst"),
      field("ipv6_dst_prefix", w.match, "ipv6_dst_prefix", "number"),
      field("ipv6_src_prefix", w.match, "ipv6_src_prefix", "number"),
    ])]));
  const modRows = MOD_FIELDS.map(k => el("div", { class: "row", style: "gap:8px" }, [
    el("div", { style: "width:80px;color:var(--dim);font-size:12px", text: k }),
    (() => { const wi = field("", w.mods[k], "mode", "select", ["static", "increment", "random"]);
             wi.style.flex = "0 0 140px"; return wi; })(),
    (() => { const wi = field("mask (hex, or IPv6 literal for v6)", w.mods[k], "mask");
             wi.style.flex = "1"; return wi; })(),
  ]));
  box.append(det("modifiers — per-packet field variation", [
    el("p", { class: "muted", text: "mode=static leaves the field fixed. mask picks which bits vary." }),
    ...modRows]));
  box.append(det("encap — tunnel the test frame (IPIP / GRE / EtherIP)", [
    el("div", { class: "grid" }, [
      field("type", w.encap, "type", "select", ["none", "ipip", "gre", "etherip"]),
      field("outer L3", w.encap, "l3", "select", ["ipv4", "ipv6"]),
      field("outer src", w.encap, "src"), field("outer dst", w.encap, "dst"),
      field("outer ttl / hop_limit", w.encap, "ttl", "number"),
      field("outer dscp", w.encap, "dscp", "number"),
      field("inner src MAC (etherip)", w.encap, "inner_src_mac"),
      field("inner dst MAC (etherip)", w.encap, "inner_dst_mac"),
      field("rx_expect", w, "rx_expect", "select", ["inner", "tunneled"]),
    ])]));

  // per-editor actions: commit the staged edits into the config/YAML, or revert.
  // (Writing to the FPGA is the top "Write to card" button.)
  const applyBtn = el("button", { class: "act ed-apply", text: "Apply edit",
    title: "Commit these edits into the config / YAML preview (does NOT write to the card)" });
  const revertBtn = el("button", { class: "act ghost ed-revert", text: "Revert",
    title: "Discard the edits and restore the committed values" });
  applyBtn.disabled = revertBtn.disabled = !modified(f);
  applyBtn.addEventListener("click", () => {
    const errs = flowErrors(w);
    if (errs.length) { showMsg("#flow-msg", "err", "Fix these first:\n• " + errs.join("\n• ")); return; }
    const idx = state.flows.indexOf(f);
    if (idx >= 0) { state.flows[idx] = clone(w); state.selFlow = idx; }
    if (!isRawDirty()) $("#flow-yaml").value = buildTestYaml();   // committed -> YAML preview
    refreshFlows();
    showMsg("#flow-msg", "ok", `Flow #${w.id} committed to the config. Use “Write to card” to program the FPGA.`);
  });
  revertBtn.addEventListener("click", () => { dropWorking(f); refreshFlows(); });

  // Preview the exact on-wire frame this flow's generator emits (daemon builds
  // it via the shared libpacketwyrm builder -> single source of truth with the
  // CLI/RTL). Previews the LIVE editor values (w), even before Apply/Write.
  const seqIn = el("input", { type: "number", value: "0", min: "0",
                              style: "width:80px", title: "packet sequence number" });
  const prevBtn = el("button", { class: "act ghost", text: "👁 Preview frame",
    title: "Decode + hex-dump the generated frame (does not touch the card)" });
  const out = el("pre", { class: "frame-preview", style: "display:none" });
  prevBtn.addEventListener("click", async () => {
    const errs = flowErrors(w);
    if (errs.length) { showMsg("#flow-msg", "err", "Fix these first:\n• " + errs.join("\n• ")); return; }
    const seq = Math.max(0, parseInt(seqIn.value, 10) || 0);
    const yaml = "flows:\n" + flowYaml(w) + "\n";
    const r = await rpc({ rpc: "flow.preview", yaml, id: w.id, seq });
    out.style.display = "block";
    out.textContent = "";
    if (!r || r.error) { out.textContent = "preview failed: " + (r ? r.error : "no response"); return; }
    out.textContent = renderPreview(r);
  });
  box.append(el("div", { class: "row flow-actions" }, [applyBtn, revertBtn, prevBtn,
    el("span", { class: "muted", text: "seq" }), seqIn]));
  box.append(out);
}

/* Render a flow.preview response as a decoded summary + hex dump (text). */
function renderPreview(r) {
  const d = r.decode || {};
  const hex = r.hex || "";
  const bytes = [];
  for (let i = 0; i < hex.length; i += 2) bytes.push(parseInt(hex.substr(i, 2), 16));
  let s = `flow ${r.flow} "${r.name || ""}"  template=${r.template}  ` +
          `frame_len=${r.len} B (pre-FCS)  seq=${r.seq}\n`;
  const layers = [];
  layers.push(`eth  ${d.eth_dst} <- ${d.eth_src}`);
  if (d.vlan != null) layers.push(`vlan ${d.vlan}`);
  if (d.encap) layers.push(`encap ${d.encap}`);
  if (d.l3) layers.push(d.l3);
  if (d.l4) layers.push(d.l4);
  if (r.template === "test") layers.push("test-hdr");
  s += "  " + layers.join(" / ") + "\n";
  if (d.mod) s += "  modifiers: " + d.mod + "  (fields vary per seq — change seq)\n";
  const show = Math.min(bytes.length, (r.header_len || 0) + 16);
  for (let b = 0; b < show; b += 16) {
    let hexpart = "", asc = "";
    for (let j = 0; j < 16; j++) {
      if (b + j < show) {
        hexpart += bytes[b + j].toString(16).padStart(2, "0") + " ";
        const c = bytes[b + j];
        asc += (c >= 32 && c < 127) ? String.fromCharCode(c) : ".";
      } else hexpart += "   ";
      if (j === 7) hexpart += " ";
    }
    s += "  " + b.toString(16).padStart(4, "0") + "  " + hexpart + " |" + asc + "|\n";
  }
  if (bytes.length > show) s += `  ... +${bytes.length - show} payload bytes (zero-filled)\n`;
  s += "  note: timestamp stamped by HW at egress (shown 0); L4 csum computed for this seq.";
  return s;
}

export function refreshFlows() {
  renderFlowList();
  // Don't clobber the raw editor if the user has manual edits there.
  if (!isRawDirty()) $("#flow-yaml").value = buildTestYaml();
}

// Shared "Write to card": program the COMMITTED config (flows + forwards) onto
// the FPGA via config.load. Used by both the Flows and Forwards tabs; msgSel is
// where to report. Blocks on manual raw-YAML edits, validates flows + forwards,
// and warns about any uncommitted staged editor edits (across both).
export async function writeToCard(msgSel) {
  if (isRawDirty()) {
    showMsg(msgSel, "warn", "You have manual raw-YAML edits. Use “Apply raw YAML” to write "
      + "them to the card, or “Regenerate from form” to discard them first.");
    return;
  }
  const errs = [...state.flows.flatMap(flowErrors), ...state.fwds.flatMap(fwdErrors)];
  if (errs.length) { showMsg(msgSel, "err", "Fix these before writing:\n• " + errs.join("\n• ")); return; }
  const pending = state.flows.filter(modified).length + state.fwds.filter(modified).length;
  const warn = pending ? `\n\n${pending} item(s) have uncommitted editor edits — "Apply edit" them first `
    + "to include them; this writes the committed config only." : "";
  if (!await confirmDialog("Write this config to the card? It replaces the running test config on the FPGA." + warn, { ok: "Write to card" })) return;
  const yaml = buildTestYaml();
  $("#flow-yaml").value = yaml; setRawDirty(false);
  const r = await rpc({ rpc: "config.load", yaml });
  if (r.ok) showMsg(msgSel, "ok", `Written to card: ${r.n_flows} flows, ${r.n_classifier_rows} classifier rows`);
  else showMsg(msgSel, "err", r.error || JSON.stringify(r));
}

export function initFlows() {
  $("#flow-add").addEventListener("click", () => { state.flows.push(newFlow()); state.selFlow = state.flows.length - 1; refreshFlows(); });
  // Track manual edits to the raw YAML so the form can't silently clobber them.
  $("#flow-yaml").addEventListener("input", () => setRawDirty(true));
  // Tab inserts two spaces (YAML) instead of moving focus out of the editor.
  $("#flow-yaml").addEventListener("keydown", e => {
    if (e.key !== "Tab") return;
    e.preventDefault();
    const ta = e.target, s = ta.selectionStart, en = ta.selectionEnd;
    ta.value = ta.value.slice(0, s) + "  " + ta.value.slice(en);
    ta.selectionStart = ta.selectionEnd = s + 2;
    setRawDirty(true);
  });
  $("#flow-yaml-regen").addEventListener("click", () => { $("#flow-yaml").value = buildTestYaml(); setRawDirty(false); });
  // Save the current test-config YAML to a local file (client-side, no daemon).
  $("#flow-yaml-save").addEventListener("click", async () => {
    // Warn if staged editor edits aren't in the YAML yet (same footgun as Write).
    const pending = state.flows.filter(modified).length + state.fwds.filter(modified).length;
    if (pending && !isRawDirty() &&
        !await confirmDialog(`${pending} item(s) have uncommitted editor edits not in this YAML `
          + "(Apply edit them first to include). Save the committed YAML anyway?", { ok: "Save" })) return;
    const blob = new Blob([$("#flow-yaml").value], { type: "text/yaml" });
    const url = URL.createObjectURL(blob);
    const a = el("a", { href: url, download: "packetwyrm-flows.yaml" });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  // Load a YAML file into the raw editor (then "Apply raw YAML" writes it to the card).
  $("#flow-yaml-loadfile").addEventListener("click", () => $("#flow-yaml-file").click());
  $("#flow-yaml-file").addEventListener("change", async e => {
    const file = e.target.files && e.target.files[0];
    e.target.value = "";   // allow re-selecting the same file later
    if (!file) return;
    const text = await file.text();
    $("#flow-yaml").value = text; setRawDirty(true); $("#flow-yaml-details").open = true;
    const v = validateYaml(text);
    if (!v.ok) showMsg("#flow-msg", "warn", `Loaded ${file.name}, but YAML syntax error${v.line ? ` (line ${v.line})` : ""}: ${v.msg}`);
    else showMsg("#flow-msg", "ok", `Loaded ${file.name} into the YAML editor. Review, then “Apply raw YAML” to write to the card.`);
  });
  // Copy-as-CLI: put the test-config YAML on the clipboard and show the
  // equivalent pktwyrm command sequence in a copyable snippet (the GUI's
  // "Write to card + Arm + Start" expressed as CLI, for scripts/soak runs).
  $("#flow-copy-cli").addEventListener("click", async () => {
    // Same precedence as Write to card: manual raw-YAML edits win.
    const yaml = isRawDirty() ? $("#flow-yaml").value : buildTestYaml();
    const ok = await copyText(yaml, "test-config YAML copied to clipboard");
    const c = cliBase();
    $("#flow-cli-cmd").textContent = `${c} load packetwyrm-flows.yaml && ${c} test arm && ${c} test start`;
    $("#flow-cli-snip").hidden = false;
    if (ok) showMsg("#flow-msg", "ok", "YAML copied — save it as packetwyrm-flows.yaml "
      + "(or use “Save to file” below), then run the command sequence shown.");
  });
  $("#flow-cli-copy").addEventListener("click",
    () => copyText($("#flow-cli-cmd").textContent, "command sequence copied"));
  $("#flow-load").addEventListener("click", e => withPending(e.currentTarget, async () => {
    const r = await rpc({ rpc: "config.get_test" });
    if (r.error) { showMsg("#flow-msg", "err", r.error); return; }   // keep any manual edits
    const jf = Array.isArray(r.flows) ? r.flows : [];
    const jw = Array.isArray(r.forwards) ? r.forwards : [];
    const hasForm = jf.length || jw.length;
    const hasYaml = r.yaml && r.yaml.trim();
    if (!hasForm && !hasYaml) {
      showMsg("#flow-msg", "warn", "No test config loaded yet (load one via Write to card, "
        + "`pktwyrm load`, or the daemon's -t). Nothing to edit.");
      return;   // nothing loaded -> don't disturb the editor / dirty state
    }
    setRawDirty(false);   // a successful load replaces the editor
    if (hasForm) {
      state.flows = jf.map(flowFromJson);   // fresh objects -> fresh (unmodified) working copies
      state.fwds = jw.map(fwdFromJson);
      state.selFlow = state.flows.length ? 0 : null;
      state.selFwd = state.fwds.length ? 0 : null;
      refreshFlows();
      renderFwdList();
    }
    if (hasYaml) $("#flow-yaml").value = r.yaml;
    $("#flow-yaml-details").open = true;
    showMsg("#flow-msg", "ok",
      `Loaded ${state.flows.length} flow(s)${state.fwds.length ? ` + ${state.fwds.length} forward(s)` : ""} `
      + "into the form and the YAML editor.");
  }));
  // Top button: WRITE TO CARD (program the committed config on the FPGA).
  $("#flow-apply").addEventListener("click", e => withPending(e.currentTarget, () => writeToCard("#flow-msg")));
  $("#flow-apply-raw").addEventListener("click", e => withPending(e.currentTarget, async () => {
    const v = validateYaml($("#flow-yaml").value);
    if (!v.ok) { showMsg("#flow-msg", "err", `YAML syntax error${v.line ? ` (line ${v.line})` : ""}: ${v.msg}`); return; }
    if (!await confirmDialog("Write the raw YAML to the card? It replaces the running test config on the FPGA.", { ok: "Write raw" })) return;
    const r = await rpc({ rpc: "config.load", yaml: $("#flow-yaml").value });
    if (r.ok) showMsg("#flow-msg", "ok", `Written to card (raw): ${r.n_flows} flows, ${r.n_classifier_rows} classifier rows`);
    else showMsg("#flow-msg", "err", r.error || JSON.stringify(r));
  }));
}
