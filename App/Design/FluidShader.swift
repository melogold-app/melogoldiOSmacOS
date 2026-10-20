#if os(iOS) || os(macOS)
/// Шейдер живого фона «Сейчас играет» (задание 0031): жидкая обложка + лава-лампа + пульс на бас — перевод один в один
/// эталона Linux `crates/melogold-gtk/resources/shaders/fluid.vert` и `fluid.frag` (GLSL ES 3.00), числа и порядок действий
/// те же. Отличия только в записи: униформы — одной структурой (палитра — float4, в шейдере берётся `.rgb`), выборка мипа —
/// `sample(…, level(lod))` вместо `textureLod`, сэмплер — трилинейный с зеркальным повтором, как у Linux.
///
/// Исходник собирается во время работы (`MTLDevice.makeLibrary(source:)`), как GLSL у Linux: сборке приложения не нужен
/// отдельный Metal Toolchain (с Xcode 26 он ставится отдельно), а ошибка сборки шейдера — не падение, а запасной фон
/// задания 0030.
nonisolated enum FluidShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct FluidUniforms {
    float4 pal[6];
    float blob[6];
    float share[6];
    float2 res;
    float liquid, liquidFlow, lavaFlow, pulse, lavaMix, loud, luma;
    float liquidBase, blobScale, zoom, lodBase, lodPulse, bright, sat;
    // Непрозрачность кадра: 1, а при смене обложки новая проявляется поверх старой
    float alpha;
    int palCount;
};

struct FluidVarying {
    float4 position [[position]];
    float2 vUv;
};

// Один треугольник на всю область; vUv — от левого нижнего угла, как в GL
vertex FluidVarying fluidVertex(uint vertexID [[vertex_id]]) {
    float2 pos = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    FluidVarying out;
    out.vUv = pos;
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

constexpr sampler coverSampler(address::mirrored_repeat, filter::linear, mip_filter::linear);

static float2 rot(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c)) * p;
}

static float3 blurAt(texture2d<float> cover, float2 uv, float lod) {
    uv.y = 1.0 - uv.y;
    float r = exp2(lod) / 256.0 * 1.4;
    float3 c = cover.sample(coverSampler, uv, level(lod)).rgb * 0.36;
    for (int i = 0; i < 4; i++) {
        float a = float(i) * 1.5708 + 0.785;
        c += cover.sample(coverSampler, uv + r * float2(cos(a), sin(a)), level(lod)).rgb * 0.16;
    }
    return c;
}

fragment float4 fluidFragment(FluidVarying in [[stage_in]],
                              constant FluidUniforms &u [[buffer(0)]],
                              texture2d<float> uCover [[texture(0)]]) {
    float2 vUv = in.vUv;
    float aspect = u.res.x / u.res.y;
    float pulse = clamp(u.pulse, 0.0, 1.0);
    // Пульс на бас: удар чуть приближает фон, собирает размытие и поднимает свет.
    // Приближение — едва (0,02): на 0,06 оно бросалось в глаза (Максим, 18.10.2026).
    float2 p = (vUv - 0.5) * float2(aspect, 1.0) * (1.0 - u.zoom * pulse);
    float lod = mix(u.lodBase, u.lodPulse, pulse);

    // Жидкая обложка: течение искажает само себя; сила и скорость — от своей полосы.
    float2 q = rot(p, u.liquidFlow * 0.045);
    float2 q2 = rot(p * 0.82, -u.liquidFlow * 0.065 + 1.5708) + 0.18 * float2(sin(u.liquidFlow * 0.059), cos(u.liquidFlow * 0.043));
    float amp = u.liquidBase + 0.62 * u.liquid;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        q += amp * 0.32 * float2(sin(q.y * 2.3 + u.liquidFlow * 0.7 + fi * 1.3), cos(q.x * 2.0 - u.liquidFlow * 0.55 + fi * 2.1));
        q2 += amp * 0.28 * float2(cos(q2.y * 1.9 - u.liquidFlow * 0.6 + fi), sin(q2.x * 2.4 + u.liquidFlow * 0.5 + fi * 1.7));
    }
    float3 col = mix(blurAt(uCover, 0.5 + q * 0.62, lod), blurAt(uCover, 0.5 + q2 * 0.62, lod + 0.5), 0.38);

    // Лава-лампа: капли цветов обложки, размер — доля цвета и своя сила звука.
    float3 acc = float3(0.0);
    float field = 0.0;
    for (int i = 0; i < 6; i++) {
        if (i >= u.palCount) break;
        float fi = float(i);
        float rad = (0.13 + 0.48 * sqrt(u.share[i])) * u.blobScale * (1.0 + 0.55 * u.blob[i]);
        float2 c = float2(sin(u.lavaFlow * 0.21 + fi * 2.4) * aspect * 0.42, cos(u.lavaFlow * 0.17 + fi * 1.7) * 0.42);
        c += 0.07 * float2(sin(u.lavaFlow * 0.9 + fi), cos(u.lavaFlow * 1.1 + fi * 2.0));
        float f = rad * rad / (dot(p - c, p - c) + 0.003);
        field += f;
        acc += u.pal[i].rgb * f;
    }
    float3 lavaCol = acc / max(field, 1e-3);
    float m = smoothstep(0.7, 1.8, field);
    col = mix(col * 0.82, lavaCol, m * u.lavaMix + 0.08);

    float k = clamp(0.30 / max(u.luma, 0.01), 0.30, 1.0) * u.bright * (1.0 + 0.16 * pulse + 0.08 * u.loud);
    float l = dot(col, float3(0.2126, 0.7152, 0.0722));
    // mix(vec3(l), col, uSat) с uSat > 1: в Metal mix вне 0…1 не определён — та же формула явно
    col = (float3(l) + (col - float3(l)) * u.sat) * k;
    float v = smoothstep(0.55, 1.0, length((vUv - 0.5) / 0.75));
    col *= 1.0 - 0.3 * v;
    return float4(clamp(col, 0.0, 1.0), u.alpha);
}
"""#
}
#endif
