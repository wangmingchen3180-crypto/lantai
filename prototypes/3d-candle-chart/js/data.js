/**
 * Simulated OHLCV series for the 3D candle prototype.
 *
 * Shape (easy to swap for live feeds later):
 *   { time: number|string, open: number, high: number, low: number, close: number, volume: number }
 */

const MINUTE_MS = 60_000;

function seededRandom(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0xffffffff;
  };
}

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

/**
 * Generate ~100 continuous OHLCV bars with trend / range / volume events.
 * @param {object} [opts]
 * @param {number} [opts.count=100]
 * @param {number} [opts.seed=42]
 * @param {number} [opts.startPrice=100]
 * @param {number} [opts.startTime] epoch ms
 * @returns {Array<{time:number,open:number,high:number,low:number,close:number,volume:number}>}
 */
export function generateOHLCV(opts = {}) {
  const count = opts.count ?? 100;
  const rand = seededRandom(opts.seed ?? 42);
  const startPrice = opts.startPrice ?? 100;
  const startTime = opts.startTime ?? Date.UTC(2024, 5, 3, 9, 30);

  /** @type {Array<{time:number,open:number,high:number,low:number,close:number,volume:number}>} */
  const bars = [];
  let price = startPrice;
  let baseVol = 1_200_000;

  for (let i = 0; i < count; i++) {
    const t = i / (count - 1);

    // Regime: uptrend → chop → dump → recovery rally
    let drift = 0;
    let volMul = 1;
    let rangeMul = 1;

    if (t < 0.28) {
      drift = 0.18;
      volMul = 0.85 + t * 0.5;
    } else if (t < 0.45) {
      drift = 0.02;
      volMul = 0.7;
      rangeMul = 0.65;
    } else if (t < 0.62) {
      drift = -0.28;
      volMul = 1.4;
      rangeMul = 1.35;
    } else if (t < 0.78) {
      drift = 0.05;
      volMul = 0.55;
      rangeMul = 0.55;
    } else {
      drift = 0.22;
      volMul = 1.1;
      rangeMul = 1.15;
    }

    // Scripted volume / candle events
    if (i === 18) volMul = 3.8; // breakout volume
    if (i === 19) volMul = 2.4;
    if (i === 42) {
      volMul = 0.25;
      rangeMul = 0.2;
    } // doji + dry volume
    if (i === 55) volMul = 4.5; // panic dump volume
    if (i === 56) volMul = 3.2;
    if (i === 72) {
      volMul = 0.35;
      rangeMul = 0.25;
    } // quiet cross
    if (i === 88) volMul = 5.2; // climax rally volume
    if (i === 89) volMul = 2.8;
    if (i === 95) {
      volMul = 0.4;
      rangeMul = 1.6;
    } // tall thin candle (price move, low vol)

    const open = price;
    const noise = (rand() - 0.5) * 1.4 * rangeMul;
    const body = drift + noise;
    let close = open + body;

    // Force a few named candle archetypes
    if (i === 22) close = open + 2.8; // big green
    if (i === 55) close = open - 3.4; // big red
    if (i === 42 || i === 72) close = open + (rand() - 0.5) * 0.15; // near-doji

    const bodyTop = Math.max(open, close);
    const bodyBot = Math.min(open, close);
    const wickUp = Math.abs(rand() * 0.9 * rangeMul);
    const wickDn = Math.abs(rand() * 0.9 * rangeMul);
    let high = bodyTop + wickUp;
    let low = bodyBot - wickDn;

    if (i === 95) {
      high = bodyTop + 1.8;
      low = bodyBot - 0.3;
    }

    high = Math.max(high, open, close);
    low = Math.min(low, open, close);

    const volume = Math.round(
      baseVol * volMul * (0.75 + rand() * 0.5) * (1 + Math.abs(body) * 0.08)
    );

    bars.push({
      time: startTime + i * 15 * MINUTE_MS,
      open: roundPrice(open),
      high: roundPrice(high),
      low: roundPrice(low),
      close: roundPrice(close),
      volume: clamp(volume, 80_000, 12_000_000),
    });

    price = close;
    baseVol *= 0.998 + rand() * 0.006;
  }

  return bars;
}

function roundPrice(n) {
  return Math.round(n * 100) / 100;
}

/**
 * Validate / normalize an external OHLCV array.
 * @param {unknown} raw
 */
export function normalizeOHLCV(raw) {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new Error("OHLCV data must be a non-empty array");
  }
  return raw.map((row, i) => {
    const open = Number(row.open);
    const high = Number(row.high);
    const low = Number(row.low);
    const close = Number(row.close);
    const volume = Number(row.volume);
    if (![open, high, low, close, volume].every(Number.isFinite)) {
      throw new Error(`Invalid OHLCV row at index ${i}`);
    }
    return {
      time: row.time,
      open,
      high: Math.max(high, open, close),
      low: Math.min(low, open, close),
      close,
      volume: Math.max(0, volume),
    };
  });
}
