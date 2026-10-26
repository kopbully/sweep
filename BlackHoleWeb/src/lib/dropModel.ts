import { pendingPosition, type Point } from "./geometry";

export interface DropItem { id: string; name: string; icon: string }
export interface DropResult { id: string; ok: boolean; error?: string }
export type FilePhase = "pending" | "absorbing" | "failed";
export interface FileVisual extends DropItem {
  phase: FilePhase;
  start: Point;
  elapsed: number;
  visible: boolean;
  error?: string;
  burst: boolean;
}
export interface ModelEvents { absorbed: FileVisual[]; finished: string[] }
export const MAX_VISIBLE_FILES = 6;
export const ABSORB_SECONDS = 1.05;
export const REBOUND_SECONDS = 0.6;

export class DropModel {
  readonly files = new Map<string, FileVisual>();
  total = 0;
  succeeded = 0;
  failed = 0;
  completed = false;

  prepare(items: DropItem[], point: Point): void {
    // An in-flight batch is retained until native results arrive. Completed batches
    // can be replaced without allowing old results to affect the next batch.
    if ((this.completed && !this.animating) || this.files.size === 0) {
      this.files.clear();
      this.total = this.succeeded = this.failed = 0;
      this.completed = false;
    }
    const known = new Set(this.files.keys());
    for (const item of items) {
      if (known.has(item.id)) continue;
      known.add(item.id);
      const index = this.total++;
      this.files.set(item.id, {
        ...item, phase: "pending", elapsed: 0, burst: false,
        visible: false,
        start: pendingPosition(point, index % MAX_VISIBLE_FILES, Math.min(items.length, MAX_VISIBLE_FILES)),
      });
    }
    this.fillVisibleSlots();
    this.completed = this.total > 0 && this.pending === 0;
  }

  complete(results: DropResult[], _point: Point): void {
    for (const result of results) {
      const file = this.files.get(result.id);
      // Native outcomes are recorded immediately. Hidden items keep elapsed=0
      // until a visible slot is available; they never finish off-screen.
      if (!file || file.phase !== "pending") continue;
      file.elapsed = 0;
      if (result.ok === true) {
        file.phase = "absorbing";
        this.succeeded++;
      } else {
        file.phase = "failed";
        file.error = result.error?.trim() || "移到废纸篓失败";
        this.failed++;
      }
    }
    this.fillVisibleSlots();
    this.completed = this.total > 0 && this.pending === 0;
  }

  advance(dt: number): ModelEvents {
    const absorbed: FileVisual[] = [];
    const finished: string[] = [];
    for (const [id, file] of this.files) {
      if (!file.visible || file.phase === "pending") continue;
      file.elapsed += dt;
      if (file.phase === "absorbing") {
        if (!file.burst && file.elapsed >= ABSORB_SECONDS * 0.88) {
          file.burst = true;
          absorbed.push(file);
        }
        if (file.elapsed >= ABSORB_SECONDS) {
          finished.push(id);
          this.files.delete(id);
        }
      } else {
        file.elapsed = Math.min(file.elapsed, REBOUND_SECONDS);
      }
    }
    // Promotions happen after this frame's integration: the next group starts
    // at progress zero and receives its own full visible animation.
    this.fillVisibleSlots();
    return { absorbed, finished };
  }

  private fillVisibleSlots(): void {
    const waiting = [...this.files.values()].filter(file => !file.visible &&
      (file.phase !== "failed" || file.elapsed < REBOUND_SECONDS));
    if (waiting.length === 0) return;
    // Keep a failed icon after rebound when there is room, but release it when
    // another file needs to present. Its exact native error remains in files.
    for (const file of this.files.values()) {
      if (file.visible && file.phase === "failed" && file.elapsed >= REBOUND_SECONDS) file.visible = false;
    }
    let free = MAX_VISIBLE_FILES - [...this.files.values()].filter(file => file.visible).length;
    for (const file of waiting) {
      if (free <= 0) break;
      file.visible = true;
      free--;
    }
  }

  get queued(): number {
    let count = 0;
    for (const file of this.files.values()) {
      if (!file.visible && (file.phase === "absorbing" || (file.phase === "failed" && file.elapsed < REBOUND_SECONDS))) count++;
    }
    return count;
  }

  get pending(): number {
    let count = 0;
    for (const file of this.files.values()) if (file.phase === "pending") count++;
    return count;
  }

  get animating(): boolean {
    for (const file of this.files.values()) {
      if (file.phase === "absorbing" || (file.phase === "failed" && file.elapsed < REBOUND_SECONDS)) return true;
    }
    return false;
  }
}
