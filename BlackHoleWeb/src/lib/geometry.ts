export interface Point { x: number; y: number }
export interface Size { width: number; height: number }
// 与 BlackHoleMetrics.side 一致：悬浮窗缩小后不再遮挡桌面。
export const WIDGET_SIZE: Size = { width: 168, height: 168 };
export const clamp01 = (value: number): number => Math.min(1, Math.max(0, Number.isFinite(value) ? value : 0));

// AppKit supplies CSS points with a top-left origin, including points outside the view.
export function toNDC(point: Point, size = WIDGET_SIZE): Point {
  return { x: point.x / size.width * 2 - 1, y: 1 - point.y / size.height * 2 };
}

export function pendingPosition(point: Point, index: number, visible: number, size = WIDGET_SIZE): Point {
  const marginX = 22;
  const marginTop = 24;
  const marginBottom = 40;
  if (index === 0) return {
    x: Math.max(marginX, Math.min(size.width - marginX, point.x)),
    y: Math.max(marginTop, Math.min(size.height - marginBottom, point.y)),
  };
  const angle = index / Math.max(visible, 2) * Math.PI * 2;
  const radius = Math.min(size.width, size.height) * 0.26;
  return {
    x: Math.max(marginX, Math.min(size.width - marginX, point.x + Math.cos(angle) * radius)),
    y: Math.max(marginTop, Math.min(size.height - marginBottom, point.y + Math.sin(angle) * radius * 0.86)),
  };
}

export interface Pose extends Point { rotation: number; scaleX: number; scaleY: number; opacity: number }

export function spiralPose(start: Point, progress: number, size = WIDGET_SIZE): Pose {
  const t = clamp01(progress);
  const cx = size.width / 2;
  const cy = size.height / 2;
  const dx = start.x - cx;
  const dy = start.y - cy;
  const initialRadius = Math.hypot(dx, dy);
  const angle = Math.atan2(dy, dx) + (1.3 * t + 1.7 * t * t) * Math.PI * 2;
  const radius = initialRadius * Math.pow(1 - t, 1.45);
  const scale = Math.pow(1 - t, 1.35);
  return {
    x: t === 0 ? start.x : cx + Math.cos(angle) * radius,
    y: t === 0 ? start.y : cy + Math.sin(angle) * radius * (1 - t * 0.48),
    rotation: (2.2 * t + 3 * t * t) * Math.PI,
    scaleX: scale * (1 + Math.sin(t * Math.PI) * 0.75),
    scaleY: scale * (1 - Math.sin(t * Math.PI) * 0.56),
    opacity: 1 - Math.pow(t, 5),
  };
}

export function reboundPose(start: Point, progress: number, size = WIDGET_SIZE): Pose {
  const t = clamp01(progress);
  const dx = start.x - size.width / 2;
  const dy = start.y - size.height / 2;
  const distance = Math.max(Math.hypot(dx, dy), 1);
  const bounce = Math.sin(t * Math.PI) * 14;
  return { x: start.x + (distance > 1 ? dx / distance : 1) * bounce, y: start.y + dy / distance * bounce, rotation: Math.sin(t * Math.PI * 3) * 0.12 * (1 - t), scaleX: 1, scaleY: 1, opacity: 1 };
}
