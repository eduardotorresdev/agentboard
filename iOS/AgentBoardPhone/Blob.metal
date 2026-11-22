#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The Mac's sky blob (Sources/AgentBoard/Board/SkyBlob.swift) drawn as distance fields: the same
// drop outline (BlobOutline.points, evaluated analytically instead of through 16 sampled
// points), the same eyes and clouds, in the same 170 x 160 point frame. Colors come in as
// uniforms from Theme; the pose comes from SwiftUI springs.

// A point of the drop's outline at angle `a`, relative to its center (BlobOutline.points).
static float2 outline(float a, float rx, float ry, float4 traits, float phase, float breath, float wobble) {
    float chubby = traits.x, tall = traits.y, tilt = traits.z, settle = traits.w;
    (void)chubby; (void)tall;
    float s = sin(a);
    float up = (1 - s) / 2;
    float edge = 1 + 0.025 * sin(3 * a + phase + breath * M_PI_F) + 0.03 * wobble * sin(5 * a + phase);
    float width = (0.62 + 0.38 * (1 - up) + settle * max(0.0, s)) * edge;
    float height = (s < 0 ? 1.04 : 0.88) * edge;
    float lean = (tilt + 0.06 * wobble) * up * up;
    return float2(cos(a) * rx * width + lean * rx, s * ry * height);
}

// Coverage (0...1) from a signed distance in points, for a soft one-point edge.
static float cover(float distance) { return clamp(0.5 - distance, 0.0, 1.0); }

static float ellipse(float2 p, float2 center, float2 radius) {
    float2 q = (p - center) / radius;
    return (length(q) - 1) * min(radius.x, radius.y);
}

static float capsule(float2 p, float2 center, float2 half_size) {
    float r = min(half_size.x, half_size.y);
    float2 q = abs(p - center) - (half_size - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// CloudPuff: three ellipses in a 34 x 18 box centered at `c`, scaled by `k`.
static float cloud(float2 p, float2 c, float k) {
    float2 o = c - float2(17, 9) * k;
    float w = 34 * k, h = 18 * k;
    float d = ellipse(p, o + float2(w * 0.25, h * 0.7), float2(w * 0.25, h * 0.3));
    d = min(d, ellipse(p, o + float2(w * 0.5, h * 0.45), float2(w * 0.25, h * 0.45)));
    d = min(d, ellipse(p, o + float2(w * 0.75, h * 0.675), float2(w * 0.25, h * 0.325)));
    return d;
}

// SparkleShape: four quadratic curves through the 14 x 14 box's edge midpoints with the center
// as control point, which are parabolas: sqrt|x| + sqrt|y| = sqrt(h). Approximate distance.
static float sparkle(float2 p, float2 c, float k) {
    float h = 7 * k;
    float2 q = abs(p - c) / h;
    return (sqrt(q.x) + sqrt(q.y) - 1) * h * 0.5;
}

static half4 over(half4 below, half4 color, float coverage) {
    half a = half(coverage) * color.a;
    return half4(color.rgb * a, a) + below * (1 - a);
}

// pose: lift, look, eyes, trail. motion: breath, wobble. traits: chubby, tall, tilt, settle.
[[ stitchable ]] half4 blob(float2 p, half4 current, float4 pose, float2 motion, float4 traits, float phase,
                            half4 deep, half4 white, half4 cloudColor, float sparkles, half4 sparkleColor) {
    float lift = pose.x, look = pose.y, eyes = pose.z, trail = pose.w;
    float breath = motion.x, wobble = motion.y;
    half4 color = half4(0);

    // Clouds around, drifting with the hop's follow-through (SkyBlob.surroundings).
    float3 spots[3] = { float3(-62, -96, 1), float3(64, -110, 0.8), float3(70, -48, 0.6) };
    for (int i = 0; i < 3; i++) {
        float k = spots[i].z;
        float side = (i % 2 == 0) ? 1 : -1;
        float2 c = float2(85 + spots[i].x + look * 3 * k, 160 - 8 - 9 + spots[i].y + trail * k * side);
        color = sparkles > 0.5 ? over(color, sparkleColor, cover(sparkle(p, c, k)))
                               : over(color, cloudColor, cover(cloud(p, c, k)));
    }

    // The body: an 88 x 76 box resting on the frame's bottom, lifted by the hop.
    float2 origin = float2(41, 84 - lift);
    float rx = 44 * 0.9 * traits.x, ry = 38 * 0.95 * traits.y;
    float ground = origin.y + 76 - 76 * 0.03;
    float2 center = float2(origin.x + 44, ground - ry * 0.88);
    float2 d = p - center;
    // The outline point in the pixel's direction: a few Newton-like steps on the angle.
    float target = atan2(d.y, d.x);
    float a = target;
    for (int i = 0; i < 4; i++) {
        float2 q = outline(a, rx, ry, traits, phase, breath, wobble);
        float error = atan2(q.y, q.x) - target;
        error = atan2(sin(error), cos(error));
        a -= error;
    }
    float2 q = outline(a, rx, ry, traits, phase, breath, wobble);
    color = over(color, deep, cover(length(d) - length(q)));

    // Eyes: two 12 x 19 capsules, 10 apart, 8 below the box's middle; they look and blink.
    float2 face = float2(origin.x + 44 + look * 8, origin.y + 38 + 8);
    float2 eye = float2(6, 9.5 * max(eyes, 2.5 / 19));
    float e = min(capsule(p, face - float2(11, 0), eye), capsule(p, face + float2(11, 0), eye));
    color = over(color, white, cover(e));
    return color;
}
