// Original particle shaders: charleypeng/kakabin (MIT).
export const PARTICLE_VERT = /* glsl */ `
attribute float aSize;
attribute vec3 aColor;
attribute float aAngle;
varying vec3 vColor;
varying float vAngle;
void main() {
  vColor = aColor;
  vAngle = aAngle;
  gl_Position = vec4(position.xy, 0.0, 1.0);
  gl_PointSize = aSize;
}
`;

export const PARTICLE_FRAG = /* glsl */ `
precision highp float;
varying vec3 vColor;
varying float vAngle;
void main() {
  vec2 c = gl_PointCoord - 0.5;
  float cs = cos(vAngle);
  float sn = sin(vAngle);
  vec2 rc = vec2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
  float d = length(rc * vec2(1.0, 3.0));
  float alpha = smoothstep(0.5, 0.1, d);
  if (alpha < 0.01) discard;
  gl_FragColor = vec4(vColor, alpha);
}
`;
