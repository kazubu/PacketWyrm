/* Inline-SVG sparklines + a tiny fixed-length ring buffer. Values are plotted
 * RAW (no smoothing) so momentary changes stay visible -- a tester needs to see
 * the spikes, not an averaged-out line. */
const NS = "http://www.w3.org/2000/svg";

// Per-series history. key -> number[] (most recent last), capped at `cap`.
export function makeRing(cap = 40) {
  const m = new Map();
  return {
    push(key, v) {
      let a = m.get(key);
      if (!a) { a = []; m.set(key, a); }
      a.push(Number.isFinite(v) ? v : 0);
      if (a.length > cap) a.shift();
      return a;
    },
    get(key) { return m.get(key) || []; },
    keep(keys) {   // drop series whose key is no longer present
      const live = new Set(keys);
      for (const k of m.keys()) if (!live.has(k)) m.delete(k);
    },
  };
}

// Render a sparkline SVG for `vals` (raw). Scales to [0, max(vals)] so a flat
// line at any level reads as flat; a spike stands out. Returns an <svg> node.
export function sparkline(vals, { w = 90, h = 18, color = "var(--accent)" } = {}) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("width", w); svg.setAttribute("height", h);
  svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
  svg.setAttribute("class", "spark");
  const n = vals.length;
  if (n < 2) return svg;
  const max = Math.max(...vals, 0);
  const min = Math.min(...vals, 0);
  const span = (max - min) || 1;
  const pad = 1.5, ih = h - 2 * pad;
  const x = i => (i / (n - 1)) * w;
  const y = v => pad + ih - ((v - min) / span) * ih;
  let d = "";
  for (let i = 0; i < n; i++) d += (i ? "L" : "M") + x(i).toFixed(1) + "," + y(vals[i]).toFixed(1) + " ";
  const path = document.createElementNS(NS, "path");
  path.setAttribute("d", d.trim());
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", color);
  path.setAttribute("stroke-width", "1");
  svg.append(path);
  // a dot on the latest sample
  const dot = document.createElementNS(NS, "circle");
  dot.setAttribute("cx", x(n - 1).toFixed(1)); dot.setAttribute("cy", y(vals[n - 1]).toFixed(1));
  dot.setAttribute("r", "1.6"); dot.setAttribute("fill", color);
  svg.append(dot);
  return svg;
}
