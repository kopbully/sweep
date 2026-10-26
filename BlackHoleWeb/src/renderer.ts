import * as THREE from "three";
import { BLACK_HOLE_VERT, BLACK_HOLE_FRAG } from "./shaders/blackhole";
import { PARTICLE_VERT, PARTICLE_FRAG } from "./shaders/particles";
import { HORIZON_R, orbitStep, spawnParticle, type OrbitalParticle } from "./lib/orbit";
import { HOLE_ZOOM, toNDC, WIDGET_SIZE, type Point, type Size } from "./lib/geometry";

export interface PointerState extends Point { strength: number; dragging: boolean }
type Particle = OrbitalParticle & { size: number };
const MAX_PARTICLES = 850;

export class HoleRenderer {
  private readonly renderer: THREE.WebGLRenderer;
  private readonly scene = new THREE.Scene();
  private readonly camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  private readonly uniforms = {
    uResolution: { value: new THREE.Vector2(WIDGET_SIZE.width, WIDGET_SIZE.height) },
    uTime: { value: 0 },
    uCursor: { value: new THREE.Vector2(0, 0) },
    uCursorOn: { value: 0 },
    uProximity: { value: 0 },
    uAgitation: { value: 0 },
    uFullness: { value: 0.3 },
    uEvaporate: { value: 0 },
  };
  private readonly particles: Particle[] = [];
  private readonly geometry = new THREE.BufferGeometry();
  private readonly positions = new Float32Array(MAX_PARTICLES * 3);
  private readonly sizes = new Float32Array(MAX_PARTICLES);
  private readonly colors = new Float32Array(MAX_PARTICLES * 3);
  private readonly angles = new Float32Array(MAX_PARTICLES);
  private proximity = 0;
  private agitation = 0;
  private size: Size = { ...WIDGET_SIZE };

  constructor(canvas: HTMLCanvasElement, onError: (message: string) => void) {
    this.renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: false, powerPreference: "low-power" });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.debug.onShaderError = (gl, program, vertex, fragment) => {
      onError(gl.getProgramInfoLog(program) || gl.getShaderInfoLog(fragment) || gl.getShaderInfoLog(vertex) || "WebGL 着色器编译失败");
    };
    const quadMaterial = new THREE.ShaderMaterial({
      vertexShader: BLACK_HOLE_VERT, fragmentShader: BLACK_HOLE_FRAG,
      uniforms: this.uniforms, transparent: true, depthWrite: false,
    });
    this.scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), quadMaterial));

    this.geometry.setAttribute("position", new THREE.BufferAttribute(this.positions, 3));
    this.geometry.setAttribute("aSize", new THREE.BufferAttribute(this.sizes, 1));
    this.geometry.setAttribute("aColor", new THREE.BufferAttribute(this.colors, 3));
    this.geometry.setAttribute("aAngle", new THREE.BufferAttribute(this.angles, 1));
    this.geometry.setDrawRange(0, 0);
    const particleMaterial = new THREE.ShaderMaterial({
      vertexShader: PARTICLE_VERT, fragmentShader: PARTICLE_FRAG,
      transparent: true, blending: THREE.AdditiveBlending, depthWrite: false,
    });
    const points = new THREE.Points(this.geometry, particleMaterial);
    points.frustumCulled = false;
    this.scene.add(points);
    this.resize(canvas.clientWidth || WIDGET_SIZE.width, canvas.clientHeight || WIDGET_SIZE.height);
  }

  resize(width: number, height: number): void {
    this.size = { width: Math.max(width, 1), height: Math.max(height, 1) };
    this.renderer.setSize(this.size.width, this.size.height, false);
    this.uniforms.uResolution.value.set(this.size.width * this.renderer.getPixelRatio(), this.size.height * this.renderer.getPixelRatio());
  }

  setPointer(pointer: PointerState): void {
    const ndc = toNDC(pointer, this.size);
    this.uniforms.uCursor.value.set(ndc.x, ndc.y);
    this.uniforms.uCursorOn.value = pointer.strength;
    this.proximity = pointer.strength;
    this.agitation = Math.min(1, pointer.strength * (pointer.dragging ? 1 : 0.7));
  }

  burst(point: Point, count: number): void {
    const ndc = toNDC(point, this.size);
    const r = Math.max(Math.hypot(ndc.x, ndc.y), 0.55);
    const theta = Math.atan2(ndc.y, ndc.x);
    for (let i = 0; i < count && this.particles.length < MAX_PARTICLES; i++) {
      this.particles.push({ ...spawnParticle(r * (0.92 + Math.random() * 0.2), theta + (Math.random() - 0.5) * 0.5), size: 2 + Math.random() * 3.5 });
    }
  }

  get animating(): boolean { return this.particles.length > 0; }

  render(dt: number, absorbing: boolean): void {
    const ease = 1 - Math.exp(-dt * 8);
    this.uniforms.uTime.value += dt;
    this.uniforms.uProximity.value += (this.proximity - this.uniforms.uProximity.value) * ease;
    const targetAgitation = absorbing ? 1 : this.agitation;
    this.uniforms.uAgitation.value += (targetAgitation - this.uniforms.uAgitation.value) * ease;
    let alive = 0;
    // 粒子坐标与着色器光线场同步缩放：着色器把 uv 乘上 fieldScale，
    // 所以屏幕位置要除以同一个系数（待机收拢、靠近张开）。
    const fieldScale = HOLE_ZOOM.idle + (HOLE_ZOOM.active - HOLE_ZOOM.idle) * this.uniforms.uProximity.value;
    const zoom = 1 / fieldScale;
    for (let i = this.particles.length - 1; i >= 0; i--) {
      const previous = this.particles[i];
      const p = orbitStep(previous, Math.min(dt, 0.05));
      if (!p.alive) { this.particles.splice(i, 1); continue; }
      this.particles[i] = { ...p, size: previous.size };
      const px = p.r * Math.cos(p.theta) * zoom;
      const py = p.r * Math.sin(p.theta) * 0.12 * zoom;
      this.positions[alive * 3] = px;
      this.positions[alive * 3 + 1] = py;
      this.positions[alive * 3 + 2] = 0;
      const t = Math.min(Math.max((p.r - HORIZON_R) / 0.7, 0), 1);
      const dim = 0.12 + 0.88 * t * t;
      // 冷色余烬：越靠内越偏靛蓝，靠近视界处收成冷白
      this.colors[alive * 3] = (0.30 + 0.62 * t) * dim;
      this.colors[alive * 3 + 1] = (0.52 + 0.44 * t) * dim;
      this.colors[alive * 3 + 2] = (0.88 + 0.12 * t) * dim;
      this.sizes[alive] = previous.size * (1 + (1 - t) * 2.5);
      this.angles[alive] = Math.atan2(py, px) + Math.PI / 2;
      alive++;
    }
    this.geometry.setDrawRange(0, alive);
    for (const key of ["position", "aColor", "aSize", "aAngle"]) this.geometry.attributes[key].needsUpdate = true;
    this.renderer.render(this.scene, this.camera);
  }
}
