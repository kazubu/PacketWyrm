/* Shared staged-edit machinery for the Flows and Forwards editors.
 *
 * Editing a flow/forward is STAGED in a per-object working copy (keyed by object
 * identity, so it survives collapse/re-render and never leaks into the serialised
 * model). "Apply edit" commits the working copy into the config model + the YAML
 * preview; the top "Write to card" button programs the committed config onto the
 * FPGA. The raw-YAML editor (#flow-yaml) is shared by both tabs (buildTestYaml
 * emits flows + forwards), so its dirty flag lives here too. */
import { $ } from "./dom.mjs";
import { state } from "./state.mjs";

export const clone = o => JSON.parse(JSON.stringify(o));

const working = new WeakMap();   // config object -> its staged working copy
export function workingFor(o) { let w = working.get(o); if (!w) { w = clone(o); working.set(o, w); } return w; }
export function peekWorking(o) { return working.get(o); }   // no create (for render/summary)
export function modified(o) { const w = working.get(o); return w ? JSON.stringify(w) !== JSON.stringify(o) : false; }
export function dropWorking(o) { working.delete(o); }
// any uncommitted staged edits across BOTH flows and forwards
export function anyStaged() { return state.flows.some(modified) || state.fwds.some(modified); }

// Shared raw-YAML dirty flag: when the user hand-edits #flow-yaml, form/editor
// commits must not silently clobber it.
let rawDirty = false;
export const isRawDirty = () => rawDirty;
export function setRawDirty(d) {
  rawDirty = d;
  const h = $("#flow-yaml-hint");
  if (h) h.textContent = d
    ? "Raw YAML has manual edits — form changes won't overwrite it. Use “Apply raw YAML”, or “Regenerate from form” to discard these edits."
    : "";
}
