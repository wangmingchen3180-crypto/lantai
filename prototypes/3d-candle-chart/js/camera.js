import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

/**
 * Dual-camera controller: Orthographic (default) + Perspective.
 * Preset views animate with ease-out cubic.
 */
export class CameraRig {
  /**
   * @param {HTMLElement} viewport
   * @param {THREE.WebGLRenderer} renderer
   * @param {{centerX:number, chartWidth:number, chartHeight:number}} layout
   */
  constructor(viewport, renderer, layout) {
    this.viewport = viewport;
    this.renderer = renderer;
    this.layout = layout;

    this.mode = "ortho"; // ortho | persp
    this.viewName = "iso";

    const aspect = this.#aspect();
    const frustum = this.#frustumSize();

    this.ortho = new THREE.OrthographicCamera(
      (-frustum * aspect) / 2,
      (frustum * aspect) / 2,
      frustum / 2,
      -frustum / 2,
      0.1,
      500
    );

    this.persp = new THREE.PerspectiveCamera(40, aspect, 0.1, 500);

    this.active = this.ortho;

    this.controls = new OrbitControls(this.active, renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;
    this.controls.screenSpacePanning = true;
    this.controls.minDistance = 8;
    this.controls.maxDistance = 160;
    this.controls.minZoom = 0.35;
    this.controls.maxZoom = 6;
    this.controls.target.set(layout.centerX, 0, -1.5);
    this.controls.update();

    this._anim = null;
    this.applyView("iso", false);
  }

  #aspect() {
    const w = this.viewport.clientWidth || 1;
    const h = this.viewport.clientHeight || 1;
    return w / h;
  }

  #frustumSize() {
    return Math.max(this.layout.chartWidth, this.layout.chartHeight) * 1.15;
  }

  get camera() {
    return this.active;
  }

  /**
   * Preset camera positions relative to chart center.
   * Front: look along -Z so Z depth collapses (classic Time×Price).
   * Side: look along +X so Y compresses (Time×Volume).
   * Iso: ~35° oblique — the product's hero state.
   */
  getViewPose(name) {
    const t = this.controls.target.clone();
    const dist = Math.max(this.layout.chartWidth, this.layout.chartHeight) * 1.05;

    if (name === "front") {
      return {
        position: new THREE.Vector3(t.x, t.y, dist * 0.95),
        target: t,
        up: new THREE.Vector3(0, 1, 0),
      };
    }

    if (name === "side") {
      return {
        position: new THREE.Vector3(t.x - dist * 0.95, t.y * 0.15, t.z - 2.5),
        target: new THREE.Vector3(t.x, 0, -2.5),
        up: new THREE.Vector3(0, 1, 0),
      };
    }

    // iso / 3D — ~35–40° azimuth, ~28° elevation
    const az = THREE.MathUtils.degToRad(38);
    const el = THREE.MathUtils.degToRad(28);
    const r = dist * 0.92;
    return {
      position: new THREE.Vector3(
        t.x + r * Math.sin(az) * Math.cos(el),
        t.y + r * Math.sin(el),
        t.z + r * Math.cos(az) * Math.cos(el)
      ),
      target: new THREE.Vector3(t.x, 0, -2),
      up: new THREE.Vector3(0, 1, 0),
    };
  }

  applyView(name, animate = true) {
    this.viewName = name;
    const pose = this.getViewPose(name);
    if (animate) this.#animateTo(pose);
    else this.#snapTo(pose);
  }

  setProjection(mode) {
    if (mode === this.mode) return;
    const pos = this.active.position.clone();
    const tgt = this.controls.target.clone();
    const zoom = this.active.isOrthographicCamera ? this.active.zoom : 1;

    this.mode = mode;
    this.active = mode === "ortho" ? this.ortho : this.persp;

    this.active.position.copy(pos);
    this.active.up.set(0, 1, 0);
    this.active.lookAt(tgt);

    if (this.active.isOrthographicCamera) {
      this.active.zoom = zoom;
      this.active.updateProjectionMatrix();
    } else {
      // Rough visual match when switching to perspective
      const dist = pos.distanceTo(tgt);
      this.persp.fov = 40;
      this.persp.position.copy(pos).sub(tgt).setLength(dist).add(tgt);
      this.persp.updateProjectionMatrix();
    }

    this.controls.object = this.active;
    this.controls.target.copy(tgt);
    this.controls.update();
    this.resize();
  }

  reset() {
    this.setProjection("ortho");
    this.controls.target.set(this.layout.centerX, 0, -1.5);
    if (this.active.isOrthographicCamera) {
      this.active.zoom = 1;
      this.active.updateProjectionMatrix();
    }
    this.applyView("iso", true);
  }

  resize() {
    const aspect = this.#aspect();
    const frustum = this.#frustumSize();

    this.ortho.left = (-frustum * aspect) / 2;
    this.ortho.right = (frustum * aspect) / 2;
    this.ortho.top = frustum / 2;
    this.ortho.bottom = -frustum / 2;
    this.ortho.updateProjectionMatrix();

    this.persp.aspect = aspect;
    this.persp.updateProjectionMatrix();

    this.renderer.setSize(this.viewport.clientWidth, this.viewport.clientHeight, false);
  }

  update() {
    if (this._anim) this.#tickAnim();
    this.controls.update();
  }

  #snapTo(pose) {
    this._anim = null;
    this.active.position.copy(pose.position);
    this.active.up.copy(pose.up);
    this.controls.target.copy(pose.target);
    this.active.lookAt(pose.target);
    this.controls.update();
  }

  #animateTo(pose) {
    this._anim = {
      t0: performance.now(),
      dur: 700,
      fromPos: this.active.position.clone(),
      toPos: pose.position.clone(),
      fromTarget: this.controls.target.clone(),
      toTarget: pose.target.clone(),
      up: pose.up.clone(),
    };
  }

  #tickAnim() {
    const a = this._anim;
    const u = Math.min(1, (performance.now() - a.t0) / a.dur);
    const e = 1 - Math.pow(1 - u, 3);
    this.active.position.lerpVectors(a.fromPos, a.toPos, e);
    this.controls.target.lerpVectors(a.fromTarget, a.toTarget, e);
    this.active.up.copy(a.up);
    this.active.lookAt(this.controls.target);
    if (u >= 1) this._anim = null;
  }
}
