import * as THREE from "three";
import { generateOHLCV } from "./data.js";
import { buildCandles, computeLayout } from "./candles.js";
import { createHelpers, createLights } from "./scene.js";
import { CameraRig } from "./camera.js";
import { CandlePicker } from "./interaction.js";

/**
 * Optional live-data hook.
 * Replace `loadSeries()` later with a fetch to your OHLCV API.
 * Expected: [{ time, open, high, low, close, volume }, ...]
 */
async function loadSeries() {
  // Example for future real feeds:
  // const res = await fetch("/api/ohlcv?symbol=BTCUSDT&interval=15m");
  // return normalizeOHLCV(await res.json());
  return generateOHLCV({ count: 100, seed: 20240603, startPrice: 100 });
}

async function main() {
  const viewport = document.getElementById("viewport");
  const canvas = document.getElementById("c");
  const tooltip = document.getElementById("tooltip");

  const bars = await loadSeries();
  const layout = computeLayout(bars);

  const renderer = new THREE.WebGLRenderer({
    canvas,
    antialias: true,
    alpha: true,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setSize(viewport.clientWidth, viewport.clientHeight, false);
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  scene.fog = new THREE.FogExp2(0x0a0d12, 0.012);

  scene.add(createLights());

  const chartRoot = new THREE.Group();
  chartRoot.name = "chart";
  scene.add(chartRoot);

  let helpers = createHelpers(layout);
  chartRoot.add(helpers);

  const candleRoot = new THREE.Group();
  candleRoot.name = "candles";
  chartRoot.add(candleRoot);

  let volumeMode = "relative";
  let candles = buildCandles(candleRoot, bars, layout, volumeMode);

  const rig = new CameraRig(viewport, renderer, layout);

  const picker = new CandlePicker(
    viewport,
    canvas,
    tooltip,
    () => rig.camera,
    () => candleRoot
  );

  // —— UI wiring ——
  const viewBtns = document.querySelectorAll("[data-view]");
  const projBtns = document.querySelectorAll("[data-proj]");
  const volumeSelect = document.getElementById("volume-mode");
  const resetBtn = document.getElementById("btn-reset");

  function setActive(btns, attr, value) {
    btns.forEach((b) => {
      b.classList.toggle("is-active", b.getAttribute(attr) === value);
    });
  }

  viewBtns.forEach((btn) => {
    btn.addEventListener("click", () => {
      const view = btn.getAttribute("data-view");
      setActive(viewBtns, "data-view", view);
      rig.applyView(view, true);
    });
  });

  projBtns.forEach((btn) => {
    btn.addEventListener("click", () => {
      const proj = btn.getAttribute("data-proj");
      setActive(projBtns, "data-proj", proj);
      rig.setProjection(proj);
    });
  });

  volumeSelect.addEventListener("change", () => {
    volumeMode = volumeSelect.value;
    picker.clearSelection();
    candles = buildCandles(candleRoot, bars, layout, volumeMode);
  });

  resetBtn.addEventListener("click", () => {
    picker.clearSelection();
    volumeMode = "relative";
    volumeSelect.value = "relative";
    candles = buildCandles(candleRoot, bars, layout, volumeMode);
    setActive(viewBtns, "data-view", "front");
    setActive(projBtns, "data-proj", "ortho");
    rig.reset();
  });

  // Drag cursor affordance
  canvas.addEventListener("pointerdown", () => canvas.classList.add("is-dragging"));
  window.addEventListener("pointerup", () => canvas.classList.remove("is-dragging"));

  const ro = new ResizeObserver(() => {
    rig.resize();
  });
  ro.observe(viewport);

  // Sync active view button when user finishes a manual orbit near a preset (optional skip)
  // Keep toolbar in sync only on explicit button clicks for MVP clarity.

  // Expose for automated tests / console debugging
  window.__candleChart = {
    scene,
    rig,
    candleRoot,
    bars,
    pickAtNdc(x, y) {
      const raycaster = new THREE.Raycaster();
      raycaster.setFromCamera(new THREE.Vector2(x, y), rig.camera);
      const hits = raycaster.intersectObjects(candleRoot.children, true);
      return hits.length
        ? hits[0].object.userData.candle?.index ??
            hits[0].object.parent?.userData.candle?.index
        : null;
    },
  };

  function frame() {
    rig.update();
    renderer.render(scene, rig.camera);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

main().catch((err) => {
  console.error(err);
  const viewport = document.getElementById("viewport");
  if (viewport) {
    const msg = document.createElement("p");
    msg.style.cssText = "color:#ef5350;padding:24px;font-family:monospace";
    msg.textContent = `Failed to start: ${err.message}`;
    viewport.appendChild(msg);
  }
});
