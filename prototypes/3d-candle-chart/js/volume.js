/**
 * Volume → Z-depth normalization.
 *
 * Modes:
 *   relative — volume / SMA(volume, lookback)   [default, RVOL]
 *   linear   — volume / mean(volume)
 *   log      — log1p(volume) / log1p(mean)
 */

const EPS = 1e-9;

/**
 * @param {Array<{volume:number}>} bars
 * @param {"relative"|"linear"|"log"} mode
 * @param {number} [lookback=20]
 * @returns {number[]} unitless depth factors (≈1 = normal thickness)
 */
export function computeDepthFactors(bars, mode = "relative", lookback = 20) {
  const vols = bars.map((b) => Math.max(0, b.volume));
  const mean = vols.reduce((a, b) => a + b, 0) / Math.max(vols.length, 1);

  if (mode === "linear") {
    return vols.map((v) => v / Math.max(mean, EPS));
  }

  if (mode === "log") {
    const logMean = Math.log1p(mean);
    return vols.map((v) => Math.log1p(v) / Math.max(logMean, EPS));
  }

  // relative volume vs trailing SMA
  return vols.map((_, i) => {
    const from = Math.max(0, i - lookback + 1);
    const window = vols.slice(from, i + 1);
    const avg = window.reduce((a, b) => a + b, 0) / window.length;
    return vols[i] / Math.max(avg, EPS);
  });
}

/**
 * Map unitless factor → world-space Z depth with soft clamp.
 * RVOL=1 → baseDepth; extreme values capped for readability.
 */
export function factorToDepth(factor, baseDepth = 1.2, minDepth = 0.12, maxDepth = 6) {
  const d = baseDepth * factor;
  return clamp(d, minDepth, maxDepth);
}

/**
 * Relative volume for tooltip (always trailing SMA, independent of display mode).
 */
export function relativeVolume(bars, index, lookback = 20) {
  const from = Math.max(0, index - lookback + 1);
  let sum = 0;
  for (let i = from; i <= index; i++) sum += bars[i].volume;
  const avg = sum / (index - from + 1);
  return bars[index].volume / Math.max(avg, EPS);
}

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}
