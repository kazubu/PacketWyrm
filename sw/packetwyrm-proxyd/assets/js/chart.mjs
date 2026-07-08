/* Inline-SVG sparklines + a tiny fixed-length ring buffer. Values are plotted
 * RAW (no smoothing) so momentary changes stay visible -- a tester needs to see
 * the spikes, not an averaged-out line. */
const NS = "http://www.w3.org/2000/svg";

// Per-series history. key -> value[] (most recent last), capped at `cap`.
// A value is a finite number, an object {v, lo, hi} (line value + min-max band
// bounds), or null: a GAP -- e.g. a counter reset at arm/stats.clear. Gaps
// break the line instead of drawing a bogus spike.
export function makeRing(cap = 120) {
  const m = new Map();
  return {
    push(key, v) {
      let a = m.get(key);
      if (!a) { a = []; m.set(key, a); }
      a.push(v == null ? null : v);
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

const val = p => (p && typeof p === "object") ? p.v : p;
const isNum = v => typeof v === "number" && Number.isFinite(v);

/* Persistent sparklines: one cached <svg> per series key whose <path> data is
 * updated IN PLACE each poll. The dashboard rebuilds its tables per poll and
 * re-appends the SAME node -- cheap -- instead of re-creating an SVG tree for
 * every flow every second. sparkPrune() drops series that disappeared. */
const sparkCache = new Map();   // key -> {svg, band, line, dot}

export function sparkPrune(liveKeys) {
  const live = new Set(liveKeys);
  for (const k of sparkCache.keys()) if (!live.has(k)) sparkCache.delete(k);
}

// Render/update the sparkline for series `key` from `vals` (raw; see makeRing
// for the value forms). Scale spans [min(0,…), max] over line values AND band
// bounds so a flat line reads flat and a spike stands out. Returns the <svg>.
export function spark(key, vals, { w = 90, h = 18, color = "var(--accent)" } = {}) {
  let c = sparkCache.get(key);
  if (!c) {
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("width", w); svg.setAttribute("height", h);
    svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
    svg.setAttribute("class", "spark");
    svg.setAttribute("aria-hidden", "true");   // decorative; the numbers are in the table
    const band = document.createElementNS(NS, "path");   // min-max band (behind the line)
    band.setAttribute("fill", color); band.setAttribute("opacity", "0.18");
    band.setAttribute("stroke", "none");
    const line = document.createElementNS(NS, "path");
    line.setAttribute("fill", "none"); line.setAttribute("stroke", color);
    line.setAttribute("stroke-width", "1");
    const dot = document.createElementNS(NS, "circle");  // marks the latest sample
    dot.setAttribute("r", "1.6"); dot.setAttribute("fill", color);
    svg.append(band, line, dot);
    c = { svg, band, line, dot };
    sparkCache.set(key, c);
  }
  const n = vals.length;
  let max = 0, min = 0, hasBand = false;
  for (const p of vals) {
    if (p == null) continue;
    const v = val(p);
    if (isNum(v)) { if (v > max) max = v; if (v < min) min = v; }
    if (typeof p === "object") {
      if (isNum(p.lo) && isNum(p.hi)) hasBand = true;
      if (isNum(p.lo) && p.lo < min) min = p.lo;
      if (isNum(p.hi) && p.hi > max) max = p.hi;
    }
  }
  const span = (max - min) || 1;
  const pad = 1.5, ih = h - 2 * pad;
  const x = i => (n > 1 ? (i / (n - 1)) * w : w);
  const y = v => pad + ih - ((v - min) / span) * ih;
  // line: gaps (null / non-finite) lift the pen
  let d = "", pen = false, lastI = -1;
  for (let i = 0; i < n; i++) {
    const v = val(vals[i]);
    if (!isNum(v)) { pen = false; continue; }
    d += (pen ? "L" : "M") + x(i).toFixed(1) + "," + y(v).toFixed(1) + " ";
    pen = true; lastI = i;
  }
  c.line.setAttribute("d", d.trim());
  // band: contiguous runs of {lo,hi} samples become filled polygons
  let bd = "";
  if (hasBand) {
    let run = [];
    const flush = () => {
      if (run.length >= 2) {
        bd += "M" + run.map(r => x(r[0]).toFixed(1) + "," + y(r[1]).toFixed(1)).join("L")
            + "L" + run.slice().reverse().map(r => x(r[0]).toFixed(1) + "," + y(r[2]).toFixed(1)).join("L")
            + "Z ";
      }
      run = [];
    };
    for (let i = 0; i < n; i++) {
      const p = vals[i];
      if (p && typeof p === "object" && isNum(p.lo) && isNum(p.hi)) run.push([i, p.lo, p.hi]);
      else flush();
    }
    flush();
  }
  c.band.setAttribute("d", bd.trim());
  if (lastI >= 0) {
    c.dot.setAttribute("display", "");
    c.dot.setAttribute("cx", x(lastI).toFixed(1));
    c.dot.setAttribute("cy", y(val(vals[lastI])).toFixed(1));
  } else c.dot.setAttribute("display", "none");
  return c.svg;
}
