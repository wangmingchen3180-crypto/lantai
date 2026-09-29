import * as THREE from "three";
import { COLORS } from "./candles.js";

/**
 * Subtle trading-desk style helpers: axes + restrained grid.
 * Not a math lab — just enough orientation.
 */
export function createHelpers(layout) {
  const root = new THREE.Group();
  root.name = "helpers";

  const padX = 2;
  const padY = 2;
  const maxDepth = 6.5;
  const x0 = -padX;
  const x1 = layout.chartWidth + padX;
  const y0 = -layout.chartHeight / 2 - padY;
  const y1 = layout.chartHeight / 2 + padY;
  const z0 = 0.05;
  const z1 = -maxDepth;

  // Floor grid on XY (price-time plane), very faint
  const grid = new THREE.GridHelper(
    Math.max(layout.chartWidth, layout.chartHeight) + 6,
    12,
    COLORS.grid,
    COLORS.grid
  );
  grid.rotation.x = Math.PI / 2;
  grid.position.set(layout.centerX, 0, z1 - 0.5);
  grid.material.opacity = 0.22;
  grid.material.transparent = true;
  root.add(grid);

  // Soft back plane so front view feels chart-like
  const planeGeo = new THREE.PlaneGeometry(x1 - x0 + 2, y1 - y0 + 2);
  const planeMat = new THREE.MeshBasicMaterial({
    color: 0x0e131b,
    transparent: true,
    opacity: 0.55,
    depthWrite: false,
  });
  const plane = new THREE.Mesh(planeGeo, planeMat);
  plane.position.set(layout.centerX, 0, z1 - 0.2);
  root.add(plane);

  // Axis lines from chart origin corner
  const axisOrigin = new THREE.Vector3(x0, y0, z0);
  root.add(makeAxis(axisOrigin, new THREE.Vector3(x1 + 1, y0, z0), COLORS.axisX));
  root.add(makeAxis(axisOrigin, new THREE.Vector3(x0, y1 + 1, z0), COLORS.axisY));
  root.add(makeAxis(axisOrigin, new THREE.Vector3(x0, y0, z1 - 1), COLORS.axisZ));

  // Tick marks on Y (price) — sparse
  const tickMat = new THREE.LineBasicMaterial({ color: 0x2a3548, transparent: true, opacity: 0.7 });
  const steps = 6;
  for (let i = 0; i <= steps; i++) {
    const y = y0 + ((y1 - y0) * i) / steps;
    const pts = [new THREE.Vector3(x0, y, z0), new THREE.Vector3(x0 - 0.35, y, z0)];
    const geo = new THREE.BufferGeometry().setFromPoints(pts);
    root.add(new THREE.Line(geo, tickMat));
  }

  // Sparse time ticks on X
  const xTicks = 8;
  for (let i = 0; i <= xTicks; i++) {
    const x = x0 + ((x1 - x0) * i) / xTicks;
    const pts = [new THREE.Vector3(x, y0, z0), new THREE.Vector3(x, y0 - 0.35, z0)];
    const geo = new THREE.BufferGeometry().setFromPoints(pts);
    root.add(new THREE.Line(geo, tickMat));
  }

  return root;
}

function makeAxis(from, to, color) {
  const geo = new THREE.BufferGeometry().setFromPoints([from, to]);
  const mat = new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.85 });
  return new THREE.Line(geo, mat);
}

export function createLights() {
  const root = new THREE.Group();
  root.name = "lights";

  const ambient = new THREE.AmbientLight(0xb8c4d8, 0.55);
  root.add(ambient);

  const key = new THREE.DirectionalLight(0xffffff, 1.05);
  key.position.set(40, 60, 50);
  root.add(key);

  const fill = new THREE.DirectionalLight(0x88aacc, 0.35);
  fill.position.set(-30, 20, 40);
  root.add(fill);

  const rim = new THREE.DirectionalLight(0x446688, 0.25);
  rim.position.set(0, 10, -40);
  root.add(rim);

  return root;
}
