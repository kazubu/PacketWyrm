/* Environment config tab: load/save the daemon's -e YAML file. */
import { $ } from "./dom.mjs";
import { rpc, showMsg } from "./rpc.mjs";
import { confirmDialog, withPending } from "./ui.mjs";
import { validateYaml } from "./yaml.mjs";

let envLoaded = null;   // last-loaded text, for a save-time diff

// Minimal line-set diff (added/removed non-blank lines) for a save heads-up.
// Not an LCS diff, but enough to show "what changed" on a small config file.
function diffSummary(oldText, newText) {
  const oldL = (oldText || "").split("\n"), newL = (newText || "").split("\n");
  const oldSet = new Set(oldL), newSet = new Set(newL);
  const removed = oldL.filter(l => l.trim() && !newSet.has(l));
  const added = newL.filter(l => l.trim() && !oldSet.has(l));
  if (!removed.length && !added.length) return "";
  return removed.map(l => "− " + l.trim()).concat(added.map(l => "+ " + l.trim())).join("\n");
}

export function initEnv() {
  $("#env-load").addEventListener("click", e => withPending(e.currentTarget, async () => {
    const r = await rpc({ rpc: "config.get_raw" });
    if (r.yaml != null) {
      $("#env-yaml").value = r.yaml;
      envLoaded = r.yaml;
      showMsg("#env-msg", "ok", `${r.path}${r.secret_set ? " (secret set, redacted)" : ""}`);
    } else showMsg("#env-msg", "err", r.error || JSON.stringify(r));
  }));
  $("#env-save").addEventListener("click", e => withPending(e.currentTarget, async () => {
    const text = $("#env-yaml").value;
    // Client-side YAML syntax check first (line number before the round-trip).
    const v = validateYaml(text);
    if (!v.ok) { showMsg("#env-msg", "err", `YAML syntax error${v.line ? ` (line ${v.line})` : ""}: ${v.msg}`); return; }
    // Show what changed vs the last load, so a save is never a blind overwrite.
    const diff = envLoaded != null ? diffSummary(envLoaded, text) : "";
    const prompt = "Save the environment config? It overwrites the daemon's -e file "
      + "(takes effect on the next daemon restart)."
      + (envLoaded == null ? "\n\n(Load current first to see a diff.)"
         : diff ? "\n\nChanges:\n" + diff : "\n\n(No changes vs the loaded file.)");
    if (!await confirmDialog(prompt, { ok: "Save" })) return;
    const r = await rpc({ rpc: "config.save", yaml: text });
    if (!r.ok) { showMsg("#env-msg", "err", r.error || JSON.stringify(r)); return; }
    envLoaded = text;   // saved -> becomes the new baseline for the next diff
    // config.save writes the env file but never live-applies it, so any change
    // needs a daemon restart to take effect; topology_change is called out too.
    if (r.restart_required)
      showMsg("#env-msg", "warn", "Saved to " + r.path + " — restart packetwyrmd to apply"
        + (r.topology_change ? " (topology change: cards/logical interfaces)." : "."));
    else
      showMsg("#env-msg", "ok", "Saved to " + r.path + " (no change).");
  }));
}
