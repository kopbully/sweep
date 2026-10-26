// Original gravitational orbit integration: charleypeng/kakabin (MIT).
export interface OrbitalParticle {
  r: number;
  theta: number;
  vr: number;
  vtheta: number;
  alive: boolean;
}

// 视界半径（NDC）：与 shader 中黑洞阴影边缘（~0.32 NDC）对齐
export const HORIZON_R = 0.3;

// 引力常数（NDC 单位），决定轨道尺度与坠落时标
const GM = 0.55;
// 吸积盘气体阻力系数：持续耗散角动量，使粒子无法维持圆轨道而螺旋内落
const DRAG = 0.12;

export function spawnParticle(r: number, theta: number): OrbitalParticle {
  // 亚开普勒初速（0.7 倍当地圆轨道速度）：一出生引力就大于离心力，立即开始内落
  const vtheta = Math.sqrt(GM / Math.max(r, 0.05)) * 0.7;
  return { r, theta, vr: 0, vtheta, alive: true };
}

export function orbitStep(p: OrbitalParticle, dt: number): OrbitalParticle {
  if (!p.alive) return p;
  const r = Math.max(p.r, 0.05);
  // 径向有效力：引力 -GM/r² + 离心项 vθ²/r（二维中心力场的真实形式）
  const ar = -GM / (r * r) + (p.vtheta * p.vtheta) / r;
  // 末段下坠不允许向外反弹，保证半径单调收缩
  const vr = Math.min(p.vr + ar * dt, 0);
  // 切向气体阻力：指数耗散角动量 L = r·vθ
  const vtheta = p.vtheta * Math.max(1 - DRAG * dt, 0);
  const rNew = r + vr * dt;
  // 角速度 ω = vθ/r：r 收缩 + 角动量近似守恒 → 坠落时旋转自然加快
  const theta = p.theta + (vtheta / Math.max(rNew, 0.05)) * dt;
  const alive = rNew > HORIZON_R;
  return { r: Math.max(rNew, 0), theta, vr, vtheta, alive };
}
