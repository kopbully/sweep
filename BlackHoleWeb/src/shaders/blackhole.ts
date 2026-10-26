// 光子步进积分器沿用 charleypeng/kakabin (MIT) 的伪 GR 方案：沿类测地线步进，
// 角动量守恒 + a = -1.5 h² p / r⁵，事件视界、透镜弯折、光子环都由积分自然涌现。
// 表面处理（配色、刻线盘面、双层光子环、透明背景、alpha 合成）为 Sweep 自有实现，
// 与上游的橙色连续吸积盘 + 星空底完全不同：Sweep 的黑洞是一枚浮在桌面上的冷色透镜，
// 圆外的像素完全透明，不会盖住壁纸和底下的窗口。
export const BLACK_HOLE_VERT = /* glsl */ `
void main() {
  gl_Position = vec4(position.xy, 0.0, 1.0);
}
`;

export const BLACK_HOLE_FRAG = /* glsl */ `
precision highp float;

uniform vec2 uResolution;
uniform float uTime;
uniform vec2 uCursor;      // NDC -1..1，光标引力注视
uniform float uCursorOn;   // 0/1 光标是否在窗口内
uniform float uProximity;  // 原生侧传入的接近度，0..1
uniform float uAgitation;  // 0..1 拖拽悬停激扰
uniform float uFullness;   // 0..1 垃圾桶饱食度
uniform float uEvaporate;  // 0..1 蒸发进度

#define STEPS 160
#define RS 1.0        // 史瓦西半径（场景单位）
#define PHOTON_R 1.5  // 光子球半径
#define DISK_IN 2.05  // 吸积盘内沿
#define DISK_OUT 4.90 // 吸积盘外沿（窄环更容易读成"环"而不是一团暗雾）
#define FOV 1.15      // 视场缩放
// uv 上的乘数：>1 把光场推开（画面变小），靠近时收回到 1 附近。
// 与 src/lib/geometry.ts 的 HOLE_ZOOM 必须一致。
#define ZOOM_IDLE 1.20
#define ZOOM_ACTIVE 0.88

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

// 盘面采样：冷色梯度 + 同心刻线。返回 (HDR 颜色, 覆盖率)
vec4 diskSample(float rr, float theta, vec3 rayDir, float t) {
  // 开普勒较差自转 ω ∝ r^-3/2：内圈快、外圈慢，纹理被自然剪切
  float omega = 1.5 * pow(2.6 / rr, 1.5) * (1.0 + 1.1 * uAgitation);
  float th = theta + t * omega;
  float inflow = t * 0.30;

  // 刻线来自 Sweep 的设计语言：像刻度盘上的同心细线，不是气体云的斑块。
  // 只依赖半径（不掺方位角），避免斜视时糊成螺旋网格。
  float grooves = 0.34 + 0.66 * pow(0.5 + 0.5 * sin(rr * 13.0 + inflow * 1.4), 3.0);
  grooves *= 0.86 + 0.14 * sin(rr * 31.0 + 2.1);
  // 大尺度不对称：一侧亮一侧暗，避免"圆环贴图"的对称感
  float lobe = 0.55 + 0.45 * sin(theta + 0.7 + t * 0.05);
  float band = fbm(vec2(th * 1.6, rr * 0.9 + inflow));

  float inner = smoothstep(DISK_IN, DISK_IN + 0.30, rr);
  float outer = 1.0 - smoothstep(DISK_OUT - 0.9, DISK_OUT, rr);
  float heat = pow(clamp((DISK_OUT - rr) / (DISK_OUT - DISK_IN), 0.0, 1.0), 1.25);

  // 多普勒：接近侧偏冷白、远离侧压暗偏靛
  vec3 tang = vec3(sin(theta), 0.0, -cos(theta));
  float dop = clamp(1.0 / (1.0 + 0.42 * dot(rayDir, tang)), 0.5, 1.85);

  vec3 cDeep = vec3(0.18, 0.34, 0.92);
  vec3 cMid  = vec3(0.26, 0.55, 1.00);   // 贴近 App accent #78AAFF
  vec3 cHot  = vec3(0.88, 0.97, 1.00);
  vec3 col = mix(cDeep, cMid, smoothstep(0.0, 0.55, heat));
  col = mix(col, cHot, smoothstep(0.55, 1.0, heat) * 0.9);
  col = mix(col, cMid * vec3(0.80, 0.74, 1.22), clamp(1.0 - dop, 0.0, 1.0) * 0.75);

  float density = clamp(0.42 + 0.40 * (band - 0.5) + 0.55 * grooves, 0.0, 1.15);
  float bright = (0.38 + 1.30 * heat) * (0.45 + 0.55 * lobe) * density * dop * dop;
  bright *= 0.85 + 0.40 * uFullness + 0.50 * uAgitation;

  float alpha = clamp(inner * outer * density * (1.0 - uEvaporate), 0.0, 1.0);
  return vec4(col * bright * 1.7, alpha);
}

void main() {
  vec2 uv = (gl_FragCoord.xy * 2.0 - uResolution) / min(uResolution.x, uResolution.y);
  // 待机收成小光点、靠近时张开：整条光线场一起缩放，透镜几何本身不变。
  float zoom = mix(ZOOM_IDLE, ZOOM_ACTIVE, uProximity);
  uv *= zoom;
  uv -= clamp(uCursor, vec2(-1.4), vec2(1.4)) * uProximity * 0.035;

  // 光标位置只做轻微视差（0.035），不再做局部凹陷：
  // 168pt 的小窗里，向内拉会把环面压成中心的一团小漩涡，反而抢焦点。

  // 相机：几乎平视盘面（俯仰 ~7°），透镜弧才能翻到阴影上下方
  vec3 ro = vec3(0.0, 0.9, -7.5);
  vec3 fwd = normalize(-ro);
  vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
  vec3 up = cross(right, fwd);
  vec3 rd = normalize(fwd + FOV * (uv.x * right + uv.y * up));

  vec3 p = ro;
  vec3 v = rd;
  vec3 h = cross(p, v);
  float h2 = dot(h, h);

  vec3 col = vec3(0.0);
  float transmit = 1.0;   // 前到后合成的剩余透射率
  float cover = 0.0;      // 盘面累计覆盖率（用于候选 alpha）
  float captured = 0.0;
  float minR = 1e9;       // 最近接近距离（光子环判据）
  vec3 prevP = p;

  for (int i = 0; i < STEPS; i++) {
    float r2 = dot(p, p);
    float r = sqrt(r2);
    minR = min(minR, r);
    if (r < RS) { captured = 1.0; break; }

    float dt = clamp(0.3 * (r - RS), 0.025, 0.4);
    prevP = p;
    v += p * (-1.5 * h2 / (r2 * r2 * r)) * dt;
    v = normalize(v);
    p += v * dt;

    // 盘面 y=0 穿越：插值取穿越点，前到后 alpha 合成
    if (prevP.y * p.y < 0.0) {
      float f = prevP.y / (prevP.y - p.y);
      vec3 q = mix(prevP, p, f);
      float rr = length(q.xz);
      if (rr > DISK_IN && rr < DISK_OUT) {
        vec4 d = diskSample(rr, atan(q.z, q.x), v, uTime);
        // 近乎平视时盘面被压成一条线，单点采样会出锯齿：掠射角下减淡一点，
        // 边缘就不会出现台阶状的硬边。
        d.a *= mix(0.55, 1.0, smoothstep(0.03, 0.30, abs(v.y)));
        float before = transmit;
        col += d.rgb * d.a * before;
        transmit *= 1.0 - d.a;
        cover += d.a * before;
        if (transmit < 0.02) { transmit = 0.0; break; }
      }
    }
  }

  float ndcR = length(uv);
  float radial = ndcR * zoom;   // 回到未缩放尺度，光晕才不会跟着画面一起缩

  // 双层光子环（Sweep 签名）：极细主环 + 外侧一道更淡的副环
  float ring = 0.0;
  if (captured < 0.5) {
    float main1 = exp(-pow((minR - PHOTON_R) * 14.0, 2.0));
    float echo = exp(-pow((minR - PHOTON_R * 1.16) * 9.0, 2.0));
    ring = main1 + echo * 0.28;
    col += mix(vec3(0.70, 0.89, 1.0), vec3(1.0), clamp(main1, 0.0, 1.0))
         * ring * (1.05 + 0.55 * uAgitation) * transmit;
  }

  // 冷色外晕：紧贴环外一层薄光，不铺满整块画布
  float halo = exp(-pow((radial - 0.60) * 6.5, 2.0));
  col += vec3(0.40, 0.64, 1.0) * halo * (0.03 + 0.10 * uFullness + 0.14 * uAgitation) * (1.0 - uEvaporate);

  // 视界：光线被吞掉的地方就是边界，输出纯黑而不是贴一个黑圆
  float shadow = 1.0 - smoothstep(2.50, 2.72, minR);

  // 蒸发：向外扩散的冷色闪光
  float evRing = exp(-pow((radial - 0.30 - uEvaporate * 0.9) * 6.0, 2.0)) * uEvaporate * (1.0 - uEvaporate) * 3.0;
  col += vec3(0.70, 0.88, 1.0) * evRing;

  col = 1.0 - exp(-col * 1.55);
  col = pow(col, vec3(0.92));

  // alpha 只由"有东西的地方"决定：阴影视界 + 盘面覆盖率 + 亮部光晕。
  // 圆外一律 0，桌面壁纸原样透上来；很淡的尾部不收进 alpha，免得糊出一圈灰雾。
  float lum = dot(col, vec3(0.299, 0.587, 0.114));
  float alpha = max(shadow * (1.0 - uEvaporate),
                    max(smoothstep(0.04, 0.32, cover), clamp(lum * 2.0 + evRing * 0.6, 0.0, 1.0)));
  alpha *= 1.0 - smoothstep(0.94, 1.0, ndcR);

  gl_FragColor = vec4(col, alpha);
}
`;
