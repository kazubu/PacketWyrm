/* Environment config tab: load/save the daemon's -e YAML file. */
import { $ } from "./dom.mjs";
import { rpc, showMsg } from "./rpc.mjs";
import { confirmDialog, withPending } from "./ui.mjs";

export function initEnv() {
  $("#env-load").addEventListener("click", e => withPending(e.currentTarget, async () => {
    const r = await rpc({ rpc: "config.get_raw" });
    if (r.yaml != null) {
      $("#env-yaml").value = r.yaml;
      showMsg("#env-msg", "ok", `${r.path}${r.secret_set ? " (secret set, redacted)" : ""}`);
    } else showMsg("#env-msg", "err", r.error || JSON.stringify(r));
  }));
  $("#env-save").addEventListener("click", e => withPending(e.currentTarget, async () => {
    if (!await confirmDialog("Save the environment config? It overwrites the daemon's -e file "
        + "(takes effect on the next daemon restart).", { ok: "Save" })) return;
    const r = await rpc({ rpc: "config.save", yaml: $("#env-yaml").value });
    if (!r.ok) { showMsg("#env-msg", "err", r.error || JSON.stringify(r)); return; }
    // config.save writes the env file but never live-applies it, so any change
    // needs a daemon restart to take effect; topology_change is called out too.
    if (r.restart_required)
      showMsg("#env-msg", "warn", "Saved to " + r.path + " — restart packetwyrmd to apply"
        + (r.topology_change ? " (topology change: cards/logical interfaces)." : "."));
    else
      showMsg("#env-msg", "ok", "Saved to " + r.path + " (no change).");
  }));
}
