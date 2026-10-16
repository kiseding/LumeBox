#include <flutter/runtime_effect.glsl>

// ImageFilter supplies the input size and sampler. Only background pixels are
// refracted; the widget's child is painted afterwards and stays readable.
uniform vec2 u_size;
uniform float u_time;
uniform float u_distort;
uniform float u_highlight;
uniform sampler2D u_input;
out vec4 frag_color;

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;
  #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
  #endif
  vec2 p = uv * 2.0 - 1.0;
  float edge = pow(clamp(max(abs(p.x), abs(p.y)), 0.0, 1.0), 6.0);
  vec2 normal = p / max(length(p), 0.001);
  float wave = sin(p.y * 5.0 + u_time) * 0.25 + 0.75;
  vec2 refracted = clamp(uv - normal * edge * wave * u_distort * 0.035,
                        vec2(0.001), vec2(0.999));
  vec4 color = texture(u_input, refracted);
  float light = (sin(u_time * 0.7 + p.x * 2.0 - p.y) * 0.5 + 0.5);
  float shine = edge * light * u_highlight * 0.32;
  frag_color = vec4(mix(color.rgb, vec3(color.a), shine), color.a);
}
