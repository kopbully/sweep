import { DropModel, ABSORB_SECONDS, REBOUND_SECONDS, type DropItem, type DropResult } from "./lib/dropModel";
import { clamp01, reboundPose, spiralPose, type Point } from "./lib/geometry";
import { RenderLoop } from "./lib/renderLoop";
import { HoleRenderer, type PointerState } from "./renderer";

interface NativeBridge { postMessage(message: unknown): void }
interface SweepHoleAPI {
  setPointer(pointer: PointerState): void;
  prepare(items: DropItem[], point: Point): void;
  complete(results: DropResult[], point: Point): void;
  setActive(active: boolean): void;
}
declare global {
  interface Window {
    sweepHole: SweepHoleAPI;
    webkit?: { messageHandlers?: { sweepHole?: NativeBridge } };
  }
}

const root = document.getElementById("hole")!;
const canvas = document.getElementById("space") as HTMLCanvasElement;
const filesLayer = document.getElementById("files")!;
const status = document.getElementById("status")!;
const failures = document.getElementById("failures")!;
const native = window.webkit?.messageHandlers?.sweepHole;
const model = new DropModel();
const nodes = new Map<string, HTMLDivElement>();
let pointer: PointerState = { x: 120, y: 120, strength: 0, dragging: false };
let renderer: HoleRenderer | undefined;
let loop: RenderLoop | undefined;
let nativeActive = true;
let renderFailed = false;
let statusAge = 0;
let hasBatch = false;

function post(message: unknown): void { native?.postMessage(message); }
function renderError(message: string): void {
  renderFailed = true;
  root.classList.add("render-error");
  status.textContent = `黑洞画面异常：${message}`;
  loop?.setActive(false);
  post({ type: "render-error", message });
}
function pointOrCenter(point: Point): Point {
  return { x: Number.isFinite(point?.x) ? point.x : 120, y: Number.isFinite(point?.y) ? point.y : 120 };
}
function syncActive(): void {
  loop?.setActive(nativeActive && !document.hidden && !renderFailed);
}
function drawFiles(): void {
  for (const [id, node] of nodes) {
    if (!model.files.get(id)?.visible) { node.remove(); nodes.delete(id); }
  }
  for (const file of model.files.values()) {
    if (!file.visible) continue;
    let node = nodes.get(file.id);
    if (!node) {
      node = document.createElement("div");
      node.className = "file";
      const image = document.createElement("img");
      // Native supplies a PNG data URL. Never allow paths or remote icon URLs.
      if (/^data:image\/png;base64,/i.test(file.icon)) image.src = file.icon;
      image.alt = "";
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = file.name;
      node.append(image, name);
      filesLayer.appendChild(node);
      nodes.set(file.id, node);
    }
    node.classList.toggle("failed", file.phase === "failed");
    node.title = file.phase === "failed" ? `${file.name}：${file.error}` : file.name;
    const pose = file.phase === "absorbing" ? spiralPose(file.start, file.elapsed / ABSORB_SECONDS)
      : file.phase === "failed" ? reboundPose(file.start, file.elapsed / REBOUND_SECONDS)
      : { ...file.start, rotation: Math.sin(file.elapsed * 4) * 0.04, scaleX: 1, scaleY: 1, opacity: 1 };
    node.style.transform = `translate(${pose.x - 20}px, ${pose.y - 20}px) rotate(${pose.rotation}rad) scale(${pose.scaleX}, ${pose.scaleY})`;
    node.style.opacity = String(pose.opacity);
    const name = node.lastElementChild as HTMLDivElement;
    name.style.opacity = file.phase === "absorbing" ? String(Math.max(0, 1 - file.elapsed * 3)) : "1";
  }
}
function drawFailures(): void {
  failures.replaceChildren();
  for (const file of model.files.values()) {
    if (file.phase !== "failed") continue;
    const line = document.createElement("div");
    line.className = "failure";
    line.textContent = `${file.name}：${file.error}`;
    failures.appendChild(line);
  }
}
function drawFeedback(): void {
  if (!native) {
    status.textContent = hasBatch ? `本地预览 · ${model.total} 项（未执行文件操作）` : "本地画面预览 · 未连接文件操作";
  } else if (model.pending > 0) {
    status.textContent = `${model.total} 项 · 等待系统处理 ${model.pending} 项`;
  } else if (hasBatch && (model.animating || statusAge < 4 || model.failed > 0)) {
    status.textContent = `${model.total} 项 · 已移到废纸篓 ${model.succeeded} 项${model.failed ? ` · 失败 ${model.failed} 项` : ""}`;
  } else {
    status.textContent = pointer.dragging && pointer.strength > 0 ? "松开后移到废纸篓" : "";
  }
}

window.sweepHole = {
  setPointer(value) {
    pointer = { ...pointOrCenter(value), strength: clamp01(value?.strength), dragging: value?.dragging === true };
    renderer?.setPointer(pointer);
    if (!renderFailed) drawFeedback();
  },
  prepare(items, point) {
    model.prepare(items, pointOrCenter(point));
    statusAge = 0;
    hasBatch = items.length > 0;
    drawFiles();
    drawFailures();
    if (!renderFailed) drawFeedback();
  },
  complete(results, point) {
    model.complete(results, pointOrCenter(point));
    statusAge = 0;
    drawFiles();
    drawFailures();
    if (!renderFailed) drawFeedback();
  },
  setActive(active) {
    nativeActive = active === true;
    syncActive();
  },
};

try {
  renderer = new HoleRenderer(canvas, renderError);
  renderer.render(0, false);
  loop = new RenderLoop(
    { request: callback => requestAnimationFrame(callback), cancel: id => cancelAnimationFrame(id) },
    () => model.animating || renderer!.animating ? 45 : pointer.strength > 0.02 ? 30 : 20,
    dt => {
      try {
        statusAge += dt;
        const events = model.advance(dt);
        for (const file of events.absorbed) renderer!.burst(spiralPose(file.start, 0.88), 42);
        drawFiles();
        if (events.finished.length > 0) post({ type: "animation-complete", ids: events.finished });
        renderer!.render(dt, model.animating);
        if (!renderFailed) drawFeedback();
      } catch (error) { renderError(error instanceof Error ? error.message : String(error)); }
    },
  );
  syncActive();
  if (!renderFailed) post({ type: "ready" });
} catch (error) { renderError(error instanceof Error ? error.message : String(error)); }

canvas.addEventListener("webglcontextlost", event => {
  event.preventDefault();
  renderError("WebGL 上下文已中断，请重新显示黑洞");
});
document.addEventListener("visibilitychange", syncActive);
window.addEventListener("resize", () => renderer?.resize(root.clientWidth, root.clientHeight));

// Ordinary local-file preview has pointer response but no filesystem capability.
// Native drag/drop remains owned by AppKit; the web page never reads file paths.
if (!native) {
  root.addEventListener("pointermove", event => {
    const bounds = root.getBoundingClientRect();
    const point = { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
    window.sweepHole.setPointer({ ...point, strength: clamp01(1 - Math.hypot(point.x - 120, point.y - 120) / 210), dragging: false });
  });
  root.addEventListener("pointerleave", () => window.sweepHole.setPointer({ x: 120, y: 120, strength: 0, dragging: false }));
  drawFeedback();
}
