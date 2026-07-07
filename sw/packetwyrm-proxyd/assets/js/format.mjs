/* Number / time / rate formatting for the dashboard. */
export const TICK_NS = 6.4;   // data-plane clock 156.25 MHz -> 6.4 ns/tick
export const fmt3 = v => (typeof v === "number" && !Number.isInteger(v)) ? v.toFixed(3) : v;

export function fmtTime(ns) {
  if (ns == null) return "—";
  if (ns < 1e3) return (ns < 10 ? ns.toFixed(1) : ns.toFixed(0)) + " ns";
  if (ns < 1e6) return (ns / 1e3).toFixed(2) + " µs";
  if (ns < 1e9) return (ns / 1e6).toFixed(3) + " ms";
  return (ns / 1e9).toFixed(3) + " s";
}

export function fmtRate(v) {
  if (v == null) return "—";
  if (v >= 1e6) return (v / 1e6).toFixed(2) + "M/s";
  if (v >= 1e3) return (v / 1e3).toFixed(2) + "k/s";
  return v.toFixed(0) + "/s";
}
