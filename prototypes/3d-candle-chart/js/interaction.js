import * as THREE from "three";
import { setCandleHighlight } from "./candles.js";

/**
 * Raycast hover + click selection for candle groups.
 */
export class CandlePicker {
  /**
   * @param {HTMLElement} viewport
   * @param {HTMLCanvasElement} canvas
   * @param {HTMLElement} tooltip
   * @param {() => THREE.Camera} getCamera
   * @param {() => THREE.Object3D} getCandleRoot  parent group containing candle groups
   */
  constructor(viewport, canvas, tooltip, getCamera, getCandleRoot) {
    this.viewport = viewport;
    this.canvas = canvas;
    this.tooltip = tooltip;
    this.getCamera = getCamera;
    this.getCandleRoot = getCandleRoot;

    this.raycaster = new THREE.Raycaster();
    this.raycaster.params.Line = { threshold: 0.2 };
    this.pointer = new THREE.Vector2();
    this.hovered = null;
    this.selected = null;
    this._pointerDown = null;

    canvas.addEventListener("pointermove", this.#onMove);
    canvas.addEventListener("pointerdown", this.#onDown);
    canvas.addEventListener("pointerup", this.#onUp);
    canvas.addEventListener("pointerleave", this.#onLeave);
  }

  dispose() {
    this.canvas.removeEventListener("pointermove", this.#onMove);
    this.canvas.removeEventListener("pointerdown", this.#onDown);
    this.canvas.removeEventListener("pointerup", this.#onUp);
    this.canvas.removeEventListener("pointerleave", this.#onLeave);
  }

  clearSelection() {
    this.#setHovered(null);
    if (this.selected) {
      setCandleHighlight(this.selected, false);
      this.selected = null;
    }
    this.tooltip.hidden = true;
  }

  #onDown = (e) => {
    this._pointerDown = { x: e.clientX, y: e.clientY, t: performance.now() };
  };

  #onUp = (e) => {
    if (!this._pointerDown) return;
    const dx = e.clientX - this._pointerDown.x;
    const dy = e.clientY - this._pointerDown.y;
    const dt = performance.now() - this._pointerDown.t;
    this._pointerDown = null;
    if (dx * dx + dy * dy > 16 || dt > 400) return; // treat as drag, not click

    const hit = this.#hitTest(e.clientX, e.clientY);
    if (hit) {
      if (this.selected && this.selected !== hit) {
        setCandleHighlight(this.selected, false);
      }
      this.selected = hit;
      setCandleHighlight(hit, true);
      this.#showTooltip(hit);
    } else {
      if (this.selected) {
        setCandleHighlight(this.selected, false);
        this.selected = null;
      }
      if (!this.hovered) this.tooltip.hidden = true;
    }
  };

  #onMove = (e) => {
    const hit = this.#hitTest(e.clientX, e.clientY);
    this.#setHovered(hit);
    if (hit) this.#showTooltip(hit);
    else if (this.selected) this.#showTooltip(this.selected);
    else this.tooltip.hidden = true;
  };

  #onLeave = () => {
    this.#setHovered(null);
    if (this.selected) this.#showTooltip(this.selected);
    else this.tooltip.hidden = true;
  };

  #setHovered(group) {
    if (this.hovered === group) return;
    if (this.hovered && this.hovered !== this.selected) {
      setCandleHighlight(this.hovered, false);
    }
    this.hovered = group;
    if (group) setCandleHighlight(group, true);
    this.canvas.style.cursor = group ? "pointer" : "";
  }

  #hitTest(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return null;
    this.pointer.x = ((clientX - rect.left) / rect.width) * 2 - 1;
    this.pointer.y = -((clientY - rect.top) / rect.height) * 2 + 1;
    this.raycaster.setFromCamera(this.pointer, this.getCamera());

    const root = this.getCandleRoot();
    if (!root) return null;
    const hits = this.raycaster.intersectObjects(root.children, true);
    if (!hits.length) return null;
    let obj = hits[0].object;
    // Resolve to the candle Group (not the body/wick mesh)
    while (obj && !(obj.isGroup && obj.userData?.candle)) {
      obj = obj.parent;
    }
    return obj?.userData?.candle ? obj : null;
  }

  #showTooltip(group) {
    const meta = group.userData.candle;
    const bar = meta.bar;
    const el = this.tooltip;
    el.hidden = false;
    el.classList.toggle("is-bull", meta.bullish);
    el.classList.toggle("is-bear", !meta.bullish);

    el.querySelector('[data-field="time"]').textContent = formatTime(bar.time);
    el.querySelector('[data-field="open"]').textContent = formatPrice(bar.open);
    el.querySelector('[data-field="high"]').textContent = formatPrice(bar.high);
    el.querySelector('[data-field="low"]').textContent = formatPrice(bar.low);
    el.querySelector('[data-field="close"]').textContent = formatPrice(bar.close);
    el.querySelector('[data-field="volume"]').textContent = formatVolume(bar.volume);
    el.querySelector('[data-field="rvol"]').textContent = meta.rvol.toFixed(2);
  }
}

function formatTime(t) {
  const d = new Date(typeof t === "number" ? t : Date.parse(t));
  if (Number.isNaN(d.getTime())) return String(t);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
}

function formatPrice(n) {
  return n.toFixed(2);
}

function formatVolume(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}
