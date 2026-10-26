// Adapted from charleypeng/kakabin (MIT): original ray-marched black-hole shader.
// Sweep adds proximity scale/warp and stronger agitation; the geodesic renderer,
// lensing, accretion disk and photon-ring calculations remain upstream's work.
export const BLACK_HOLE_VERT = /* glsl */ `
void main() {
  gl_Position = vec4(position.xy, 0.0, 1.0);
}
`;

// 黑洞渲染：沿类测地线步进光线（伪 GR：角动量守恒 + a = -1.5 h² p / r⁵），
// 事件视界阴影、引力透镜吸积盘（远端盘面被弯折到阴影上下方）、
// 光子环、多普勒增亮全部由光线步进自然涌现，不用屏幕空间贴片伪造。
export const BLACK_HOLE_FRAG = /* glsl */ `
precision highp float;

uniform vec2 uResolution;
uniform float uTime;
uniform vec2 uCursor;      // NDC -1..1，光标引力注视
uniform float uCursorOn;   // 0/1 光标是否在窗口内
uniform float uProximity;  // Sweep: native external proximity, 0..1
uniform float uAgitation;  // 0..1 拖拽悬停激扰
uniform float uFullness;   // 0..1 垃圾桶饱食度
uniform float uEvaporate;  // 0..1 蒸发进度

#define STEPS 160
#define RS 1.0        // 史瓦西半径（场景单位）
#define PHOTON_R 1.5  // 光子球半径
#define DISK_IN 2.0   // 吸积盘内沿（ISCO 内侧）
#define DISK_OUT 5.6  // 吸积盘外沿
#define FOV 1.15      // 视场缩放：使阴影半径（2.6 RS）落在 ~0.32 NDC

float hash21(vec2 p) {
  p = fract(p * vec2(234.34, 435.345));
  p += dot(p, p + 34.23);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * vnoise(p);
    p = p * 2.03 + 11.7;
    a *= 0.5;
  }
  return v;
}

vec3 stars(vec3 dir) {
  vec2 uv = vec2(atan(dir.z, dir.x), asin(clamp(dir.y, -1.0, 1.0)));
  uv *= vec2(3.0, 6.0);
  vec2 cell = floor(uv * 40.0);
  float h = hash21(cell);
  float twinkle = 0.3 + 0.7 * abs(sin(uTime * (0.4 + h) + h * 60.0));
  float star = step(0.995, h) * twinkle;
  vec3 tint = mix(vec3(0.65, 0.75, 1.0), vec3(1.0, 0.85, 0.65), fract(h * 7.31));
  vec3 col = star * tint * 0.35;
  // 微弱星云底色，避免纯黑背景
  col += vec3(0.030, 0.045, 0.090) * fbm(dir.xz * 2.5 + dir.y);
  return col;
}

// 吸积盘采样：返回 (HDR 颜色, 不透明度)
vec4 diskSample(float rr, float theta, vec3 rayDir, float t) {
  // 开普勒较差自转 ω ∝ r^-3/2：内圈转得快，湍流图案被自然剪切
  float omega = 1.4 * pow(2.6 / rr, 1.5) * (1.0 + 1.3 * uAgitation);
  float th = theta + t * omega;
  // 湍流丝状结构：细切向频率让转动可感知，径向内流项让纹理缓慢漂向视界（吸积感）
  float inflow = t * 0.22;
  float n  = fbm(vec2(th * 4.0, rr * 2.2 + inflow));
  float n2 = fbm(vec2(th * 8.0 + 13.7, rr * 5.0 + inflow * 1.7));
  float fil = clamp(0.45 + 0.75 * n + 0.35 * (n2 - 0.5), 0.0, 1.4);
  // 径向分布：内沿锐利、外沿羽化
  float inner = smoothstep(DISK_IN, DISK_IN + 0.35, rr);
  float outer = 1.0 - smoothstep(DISK_OUT - 2.2, DISK_OUT, rr);
  float heat = pow(clamp((DISK_OUT - rr) / (DISK_OUT - DISK_IN), 0.0, 1.0), 1.4);
  // 多普勒束流：朝向我们运动的一侧更亮更蓝，远离侧更暗更红
  vec3 tang = vec3(sin(theta), 0.0, -cos(theta));
  float dop = clamp(1.0 / (1.0 + 0.45 * dot(rayDir, tang)), 0.55, 1.9);
  vec3 warm = vec3(1.0, 0.36, 0.05);
  vec3 hot  = vec3(1.0, 0.96, 0.85);
  vec3 col = mix(warm, hot, heat * heat);
  col *= mix(vec3(1.0), vec3(0.80, 0.90, 1.15), clamp(dop - 1.0, 0.0, 1.0));
  col *= mix(vec3(1.0), vec3(1.10, 0.75, 0.55), clamp(1.0 - dop, 0.0, 1.0));
  // 细密亮环随内流缓慢移向视界，幅度克制不抢眼
  float rings = 0.88 + 0.12 * sin(rr * 16.0 + t * 1.8 + n * 4.0);
  float bright = (0.55 + 1.45 * heat) * fil * rings * dop * dop;
  bright *= 0.8 + 0.5 * uFullness + 0.5 * uAgitation;
  float alpha = clamp(inner * outer * (0.5 + 0.6 * fil), 0.0, 1.0) * (1.0 - uEvaporate);
  return vec4(col * bright * 1.9, alpha);
}

void main() {
  vec2 uv = (gl_FragCoord.xy * 2.0 - uResolution) / min(uResolution.x, uResolution.y);
  // A broad response remains visible before the pointer enters the tiny widget.
  // Scaling the ray field preserves the original lensed geometry.
  uv /= 0.84 + uProximity * 0.15;
  uv -= clamp(uCursor, vec2(-1.4), vec2(1.4)) * uProximity * 0.035;

  // 光标引力注视：图像向光标凹陷
  if (uCursorOn > 0.001) {
    vec2 d = uCursor - uv;
    float dist2 = dot(d, d);
    uv += d / (sqrt(dist2) + 1e-6) * (0.10 + 0.11 * uProximity) * uCursorOn * exp(-dist2 * 3.5);
  }

  // 相机：几乎平视吸积盘（俯仰 ~7°），透镜弧才能翻到阴影上下方
  vec3 ro = vec3(0.0, 0.9, -7.5);
  vec3 fwd = normalize(-ro);
  vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
  vec3 up = cross(right, fwd);
  vec3 rd = normalize(fwd + FOV * (uv.x * right + uv.y * up));

  // 光线步进：比角动量 h² 守恒（平面轨道），伪 GR 加速度弯折光线
  vec3 p = ro;
  vec3 v = rd;
  vec3 h = cross(p, v);
  float h2 = dot(h, h);

  vec3 col = vec3(0.0);
  float transmit = 1.0;   // 前到后合成剩余透射率
  float captured = 0.0;
  float minR = 1e9;       // 最近接近距离（光子环判据）
  vec3 prevP = p;

  for (int i = 0; i < STEPS; i++) {
    float r2 = dot(p, p);
    float r = sqrt(r2);
    minR = min(minR, r);
    if (r < RS) { captured = 1.0; break; }

    // 自适应步长：靠近视界加密
    float dt = clamp(0.3 * (r - RS), 0.025, 0.4);
    prevP = p;
    v += p * (-1.5 * h2 / (r2 * r2 * r)) * dt;
    v = normalize(v); // 保持 |v|=1，dt 即弧长
    p += v * dt;

    // 吸积盘平面 y=0 穿越：插值取穿越点，前到后 alpha 合成
    if (prevP.y * p.y < 0.0) {
      float f = prevP.y / (prevP.y - p.y);
      vec3 q = mix(prevP, p, f);
      float rr = length(q.xz);
      if (rr > DISK_IN && rr < DISK_OUT) {
        vec4 d = diskSample(rr, atan(q.z, q.x), v, uTime);
        col += d.rgb * d.a * transmit;
        transmit *= 1.0 - d.a;
        if (transmit < 0.02) { transmit = 0.0; break; }
      }
    }
  }

  // 背景星空（未被捕获且未被盘体遮挡的部分），方向取弯折后的出射方向
  if (captured < 0.5 && transmit > 0.0) {
    col += stars(normalize(v)) * transmit;
  }

  // 光子环：最近接近距离贴近光子球的光线在阴影边缘叠出亮环
  if (captured < 0.5) {
    float glow = exp(-pow(max(minR - PHOTON_R, 0.0) * 6.5, 2.0));
    col += vec3(1.0, 0.88, 0.66) * glow * (0.35 + 0.30 * uAgitation) * transmit;
  }

  // 整体柔和辉光（近似 bloom 的散射光晕），不覆盖阴影内部保持纯黑
  float ndcR = length(uv);
  col += vec3(1.0, 0.70, 0.38) * exp(-ndcR * 4.0) * smoothstep(0.30, 0.55, ndcR)
       * (0.06 + 0.18 * uFullness + 0.22 * uAgitation) * (1.0 - uEvaporate);

  // 蒸发：向外扩散的辐射闪光
  float evRing = exp(-pow((ndcR - uEvaporate * 1.6) * 8.0, 2.0)) * uEvaporate * (1.0 - uEvaporate) * 4.0;
  col += vec3(0.8, 0.9, 1.0) * evRing;

  // 圆形窗口软边
  float edge = smoothstep(1.0, 0.92, ndcR);
  col *= edge;

  // filmic 色调映射 + 亮度提升
  col = 1.0 - exp(-col * 1.6);
  col = pow(col, vec3(0.85));

  gl_FragColor = vec4(col, edge);
}
`;
