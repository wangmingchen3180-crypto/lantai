import * as THREE from "three";
import { computeDepthFactors, factorToDepth, relativeVolume } from "./volume.js";

export const COLORS = {
  bull: 0x26a69a,
  bear: 0xef5350,
  bullEmissive: 0x0a2e2b,
  bearEmissive: 0x3a1210,
  highlight: 0xffffff,
  grid: 0x1a2230,
  axisX: 0x5b8def,
  axisY: 0x4ecdc4,
  axisZ: 0xc9a227,
};

/**
 * Layout metrics mapping OHLCV → Three.js world units.
 * X = time index, Y = price, Z = volume depth (into -Z / behind front plane).
 */
export function computeLayout(bars) {
  const prices = bars.flatMap((b) => [b.high, b.low]);
  const minP = Math.min(...prices);
  const maxP = Math.max(...prices);
  const priceRange = Math.max(maxP - minP, 1e-6);

  const candleGap = 1.0;
  const bodyWidth = 0.62;
  const wickWidth = 0.1;
  const chartWidth = (bars.length - 1) * candleGap;
  const chartHeight = 28;
  const priceScale = chartHeight / priceRange;
  const yOffset = -((minP + maxP) / 2) * priceScale;

  return {
    candleGap,
    bodyWidth,
    wickWidth,
    chartWidth,
    chartHeight,
    priceScale,
    yOffset,
    minP,
    maxP,
    priceRange,
    centerX: chartWidth / 2,
    centerY: 0,
  };
}

export function priceToY(price, layout) {
  return price * layout.priceScale + layout.yOffset;
}

/**
 * Build / rebuild all candle meshes under `root`.
 * Each candle is a Group with userData.candleIndex for raycasting.
 */
export function buildCandles(root, bars, layout, volumeMode = "relative") {
  while (root.children.length) {
    const child = root.children[0];
    root.remove(child);
    child.traverse?.((obj) => {
      if (obj.geometry) obj.geometry.dispose();
      if (obj.material) {
        if (Array.isArray(obj.material)) obj.material.forEach((m) => m.dispose());
        else obj.material.dispose();
      }
    });
  }

  const factors = computeDepthFactors(bars, volumeMode, 20);
  const candles = [];

  for (let i = 0; i < bars.length; i++) {
    const bar = bars[i];
    const bullish = bar.close >= bar.open;
    const color = bullish ? COLORS.bull : COLORS.bear;
    const emissive = bullish ? COLORS.bullEmissive : COLORS.bearEmissive;

    const depth = factorToDepth(factors[i]);
    const x = i * layout.candleGap;

    const yOpen = priceToY(bar.open, layout);
    const yClose = priceToY(bar.close, layout);
    const yHigh = priceToY(bar.high, layout);
    const yLow = priceToY(bar.low, layout);

    const bodyBot = Math.min(yOpen, yClose);
    const bodyTop = Math.max(yOpen, yClose);
    const bodyH = Math.max(bodyTop - bodyBot, 0.06);
    const wickH = Math.max(yHigh - yLow, 0.04);

    const mat = new THREE.MeshStandardMaterial({
      color,
      emissive,
      emissiveIntensity: 0.35,
      roughness: 0.45,
      metalness: 0.08,
      flatShading: false,
    });

    const group = new THREE.Group();
    group.name = `candle-${i}`;
    group.position.set(x, 0, 0);

    // Body — front face near z=0, depth extends toward -Z (into screen)
    const bodyGeo = new THREE.BoxGeometry(layout.bodyWidth, bodyH, depth);
    const body = new THREE.Mesh(bodyGeo, mat);
    body.position.set(0, bodyBot + bodyH / 2, -depth / 2);
    body.castShadow = false;
    body.receiveShadow = false;

    // Wick shares the same Z depth so thickness stays coherent when rotated
    const wickGeo = new THREE.BoxGeometry(layout.wickWidth, wickH, Math.max(depth * 0.35, 0.08));
    const wick = new THREE.Mesh(wickGeo, mat);
    wick.position.set(0, yLow + wickH / 2, -depth / 2);

    group.add(wick);
    group.add(body);

    const meta = {
      index: i,
      bar,
      depth,
      factor: factors[i],
      rvol: relativeVolume(bars, i, 20),
      bullish,
      baseColor: color,
      baseEmissive: emissive,
      materials: [mat],
    };

    group.userData.candle = meta;
    body.userData.candle = meta;
    wick.userData.candle = meta;

    root.add(group);
    candles.push(group);
  }

  return candles;
}

/**
 * Highlight / clear highlight on a candle group.
 */
export function setCandleHighlight(group, active) {
  if (!group?.userData?.candle) return;
  const { materials, baseColor, baseEmissive } = group.userData.candle;
  for (const mat of materials) {
    if (active) {
      mat.emissive.setHex(COLORS.highlight);
      mat.emissiveIntensity = 0.55;
      mat.color.setHex(baseColor);
    } else {
      mat.emissive.setHex(baseEmissive);
      mat.emissiveIntensity = 0.35;
      mat.color.setHex(baseColor);
    }
  }
}
