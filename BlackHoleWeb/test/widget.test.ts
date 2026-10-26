import { describe, expect, it } from "vitest";
import { pendingPosition, reboundPose, spiralPose, toNDC } from "../src/lib/geometry";
import { ABSORB_SECONDS, DropModel, MAX_VISIBLE_FILES, REBOUND_SECONDS } from "../src/lib/dropModel";
import { RenderLoop, type AnimationDriver } from "../src/lib/renderLoop";
import { HORIZON_R, orbitStep, spawnParticle } from "../src/lib/orbit";

describe("native CSS geometry", () => {
  it("converts top-left CSS points and retains outside coordinates", () => {
    expect(toNDC({ x: 0, y: 0 })).toEqual({ x: -1, y: 1 });
    expect(toNDC({ x: 120, y: 120 })).toEqual({ x: 0, y: 0 });
    expect(toNDC({ x: 300, y: -60 })).toEqual({ x: 1.5, y: 1.5 });
  });
  it("starts at the actual drop and shrinks along a rotating path into the center", () => {
    const point = { x: 182, y: 65 };
    expect(pendingPosition(point, 0, 2)).toEqual(point);
    expect(spiralPose(point, 0)).toMatchObject(point);
    const mid = spiralPose(point, 0.5);
    const end = spiralPose(point, 1);
    expect(mid.rotation).toBeGreaterThan(Math.PI);
    expect(mid.scaleX).toBeGreaterThan(mid.scaleY);
    expect(Math.hypot(mid.x - 120, mid.y - 120)).toBeLessThan(Math.hypot(62, -55));
    expect(end).toMatchObject({ x: 120, y: 120, scaleX: 0, scaleY: 0, opacity: 0 });
    expect(spiralPose({ x: 120, y: 120 }, 0.001)).toMatchObject({ x: 120, y: 120 });
    expect(reboundPose(point, 1)).toMatchObject({ ...point, scaleX: 1, scaleY: 1, opacity: 1 });
  });
});

describe("native-confirmed result states", () => {
  const items = [
    { id: "ok", name: "真实文件.pdf", icon: "data:image/png;base64,one" },
    { id: "bad", name: "<script>text</script>", icon: "data:image/png;base64,two" },
  ];
  const point = { x: 170, y: 80 };
  it("never absorbs during prepare or a pending wait", () => {
    const model = new DropModel();
    model.prepare(items, point);
    model.advance(200);
    expect(model.files.get("ok")?.phase).toBe("pending");
    expect(model.files.get("ok")?.elapsed).toBe(0);
    expect(model.succeeded).toBe(0);
    expect(model.animating).toBe(false);
  });
  it("animates success and failure independently and preserves native failure reason", () => {
    const model = new DropModel();
    model.prepare(items, point);
    model.complete([{ id: "ok", ok: true }, { id: "bad", ok: false, error: "权限不足（系统返回）" }], point);
    expect(model.files.get("ok")?.phase).toBe("absorbing");
    expect(model.files.get("bad")?.phase).toBe("failed");
    expect(model.files.get("bad")?.error).toBe("权限不足（系统返回）");
    const event = model.advance(ABSORB_SECONDS);
    expect(event.absorbed.map(file => file.id)).toEqual(["ok"]);
    expect(event.finished).toEqual(["ok"]);
    expect(model.files.has("ok")).toBe(false);
    expect(model.files.get("bad")?.name).toBe(items[1].name);
    expect(model.advance(10).finished).toEqual([]);
    expect(model.succeeded).toBe(1);
    expect(model.failed).toBe(1);
  });
  it("queues every success beyond six and gives each visible group its full animation", () => {
    const model = new DropModel();
    const batch = Array.from({ length: 20 }, (_, i) => ({ id: String(i), name: `${i}.png`, icon: "" }));
    model.prepare(batch, point);
    expect(model.total).toBe(20);
    expect([...model.files.values()].filter(file => file.visible)).toHaveLength(MAX_VISIBLE_FILES);
    model.complete(batch.map(file => ({ id: file.id, ok: true })), point);
    expect(model.succeeded).toBe(20);
    expect(model.queued).toBe(14);
    const shown = new Set<string>();
    const finished: string[] = [];
    for (let group = 0; group < 4; group++) {
      const visible = [...model.files.values()].filter(file => file.visible);
      expect(visible.length).toBe(Math.min(MAX_VISIBLE_FILES, 20 - group * MAX_VISIBLE_FILES));
      for (const file of visible) { shown.add(file.id); expect(file.elapsed).toBe(0); }
      expect(model.advance(ABSORB_SECONDS / 2).finished).toEqual([]);
      for (const file of model.files.values()) if (!file.visible) expect(file.elapsed).toBe(0);
      const event = model.advance(ABSORB_SECONDS / 2);
      expect(event.finished).toEqual(visible.map(file => file.id));
      finished.push(...event.finished);
      expect(model.queued).toBe(Math.max(0, 20 - (group + 2) * MAX_VISIBLE_FILES));
    }
    expect([...shown]).toEqual(batch.map(file => file.id));
    expect(finished).toEqual(batch.map(file => file.id));
    expect(model.animating).toBe(false);
  });
  it("presents queued failures and successes separately while keeping every native error", () => {
    const model = new DropModel();
    const batch = Array.from({ length: 10 }, (_, i) => ({ id: String(i), name: `${i}.pdf`, icon: "" }));
    const results = batch.map((file, i) => ({ id: file.id, ok: [0, 2, 4, 7, 9].includes(i), error: `系统原因 ${i}` }));
    model.prepare(batch, point);
    model.complete(results, point);
    expect(model.succeeded).toBe(5);
    expect(model.failed).toBe(5);
    const shownSuccesses = new Set<string>();
    const shownFailures = new Set<string>();
    const finished: string[] = [];
    for (let step = 0; step < 6; step++) {
      const visible = [...model.files.values()].filter(file => file.visible);
      expect(visible.length).toBeLessThanOrEqual(MAX_VISIBLE_FILES);
      for (const file of visible) (file.phase === "failed" ? shownFailures : shownSuccesses).add(file.id);
      finished.push(...model.advance(REBOUND_SECONDS).finished);
    }
    expect([...shownSuccesses].sort()).toEqual(["0", "2", "4", "7", "9"]);
    expect([...shownFailures].sort()).toEqual(["1", "3", "5", "6", "8"]);
    expect([...finished].sort()).toEqual(["0", "2", "4", "7", "9"]);
    expect(new Set(finished).size).toBe(finished.length);
    for (const result of results.filter(result => !result.ok)) {
      expect(model.files.get(result.id)).toMatchObject({ phase: "failed", error: result.error, elapsed: REBOUND_SECONDS });
    }
    expect(model.animating).toBe(false);
  });
  it("releases completed failure icons so later failures also receive a visible rebound", () => {
    const model = new DropModel();
    const batch = Array.from({ length: 8 }, (_, i) => ({ id: String(i), name: `${i}.pdf`, icon: "" }));
    model.prepare(batch, point);
    model.complete(batch.map(file => ({ id: file.id, ok: false, error: `error ${file.id}` })), point);
    expect(model.advance(REBOUND_SECONDS).finished).toEqual([]);
    expect(model.files.get("6")).toMatchObject({ phase: "failed", visible: true, elapsed: 0 });
    expect(model.files.get("7")).toMatchObject({ phase: "failed", visible: true, elapsed: 0 });
    expect(model.files.get("0")?.visible).toBe(false);
    expect(model.advance(REBOUND_SECONDS).finished).toEqual([]);
    expect(model.failed).toBe(8);
    expect(model.files.size).toBe(8);
    expect(model.animating).toBe(false);
  });
  it("ignores duplicate/unknown results and preserves pending items across partial results", () => {
    const model = new DropModel();
    model.prepare(items, point);
    model.complete([{ id: "ok", ok: true }, { id: "unknown", ok: true }], point);
    model.complete([{ id: "ok", ok: false, error: "late" }], point);
    expect(model.pending).toBe(1);
    expect(model.succeeded).toBe(1);
    expect(model.failed).toBe(0);
    expect(model.completed).toBe(false);
  });
  it("keeps confirmed animations when a second drop arrives before they finish", () => {
    const model = new DropModel();
    model.prepare([items[0]], point);
    model.complete([{ id: "ok", ok: true }], point);
    model.prepare([items[1]], point);
    expect(model.files.get("ok")?.phase).toBe("absorbing");
    expect(model.files.get("bad")?.phase).toBe("pending");
    expect(model.pending).toBe(1);
    expect(model.completed).toBe(false);
    expect(model.advance(2).finished).toEqual(["ok"]);
    expect(model.files.get("bad")?.phase).toBe("pending");
  });
});

describe("throttled visible lifecycle", () => {
  it("keeps the visible group and waiting icons paused while hidden, with no catch-up on resume", () => {
    const model = new DropModel();
    const batch = Array.from({ length: 8 }, (_, i) => ({ id: String(i), name: `${i}.pdf`, icon: "" }));
    model.prepare(batch, { x: 170, y: 80 });
    model.complete(batch.map(file => ({ id: file.id, ok: true })), { x: 170, y: 80 });
    let nextID = 0;
    const frames = new Map<number, FrameRequestCallback>();
    const driver: AnimationDriver = {
      request(callback) { const id = ++nextID; frames.set(id, callback); return id; },
      cancel(id) { frames.delete(id); },
    };
    const step = (time: number) => {
      const [id, callback] = [...frames.entries()][0];
      frames.delete(id);
      callback(time);
    };
    const loop = new RenderLoop(driver, () => 45, dt => { model.advance(dt); });
    loop.setActive(true);
    step(0);
    for (let i = 1; i <= 14; i++) step(i * 70);
    expect(model.files.get("6")).toMatchObject({ visible: false, elapsed: 0 });
    expect(model.queued).toBe(2);
    loop.setActive(false);
    expect(frames.size).toBe(0);
    const before = JSON.stringify([...model.files.values()]);
    loop.setActive(true);
    step(100000);
    expect(JSON.stringify([...model.files.values()])).toBe(before);
    step(100070);
    expect(model.files.get("6")).toMatchObject({ visible: true, elapsed: 0 });
    expect(model.files.get("7")).toMatchObject({ visible: true, elapsed: 0 });
    expect(model.files.size).toBe(2);
    expect(model.queued).toBe(0);
    loop.setActive(false);
  });
  it("uses 20/30/45 fps ceilings and queues no frames when hidden", () => {
    let nextID = 0;
    const frames = new Map<number, FrameRequestCallback>();
    const driver: AnimationDriver = {
      request(callback) { const id = ++nextID; frames.set(id, callback); return id; },
      cancel(id) { frames.delete(id); },
    };
    const step = (time: number) => {
      const frame = [...frames.entries()][0];
      expect(frame).toBeDefined();
      frames.delete(frame[0]);
      frame[1](time);
    };
    let fps = 20;
    const deltas: number[] = [];
    const loop = new RenderLoop(driver, () => fps, dt => deltas.push(dt));
    loop.setActive(true);
    step(0); step(20); step(49); step(50);
    expect(deltas).toEqual([0, 0.05]);
    fps = 30;
    step(70); step(84);
    expect(deltas).toHaveLength(3);
    fps = 45;
    step(106); step(128);
    expect(deltas).toHaveLength(5);
    loop.setActive(false);
    expect(frames.size).toBe(0);
    loop.setActive(true);
    step(10000);
    expect(deltas.at(-1)).toBe(0);
    loop.setActive(false);
    expect(frames.size).toBe(0);
  });
});

describe("upstream gravitational orbit", () => {
  it("spirals inward without radial rebound until it crosses the horizon", () => {
    let particle = spawnParticle(0.9, 0);
    const startTheta = particle.theta;
    for (let i = 0; i < 800 && particle.alive; i++) {
      const previous = particle;
      particle = orbitStep(particle, 1 / 45);
      expect(particle.r).toBeLessThanOrEqual(previous.r);
    }
    expect(particle.alive).toBe(false);
    expect(particle.r).toBeLessThanOrEqual(HORIZON_R);
    expect(particle.theta).toBeGreaterThan(startTheta);
  });
});
