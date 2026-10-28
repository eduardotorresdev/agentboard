/// Metal source for the board. Every visible thing on the canvas is one instanced quad:
/// solid rects (cell backgrounds, grid lines), atlas glyphs, rounded rects, and soft shadows.
/// Compiled at runtime so the package needs no metallib build step.
enum LegacyShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad {
        float4 rect;    // x, y, width, height in pixels, top-left origin
        float4 uv;      // atlas x, y, width, height in pixels
        float4 color;   // straight alpha
        float4 params;  // x: kind, y: corner radius, z: shadow softness
    };

    struct Uniforms { float2 viewport; float2 atlasSize; };

    struct Fragment {
        float4 position [[position]];
        float2 local;     // pixel offset from the rect center
        float2 uv;
        float4 color;
        float4 params;
        float2 halfSize;
    };

    constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

    vertex Fragment board_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Quad *quads [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
        Quad q = quads[iid];
        float2 corner = corners[vid];
        float2 origin = q.rect.xy;
        float2 size = q.rect.zw;
        if (q.params.x == 3) {  // shadows bleed past their rect
            float spread = q.params.z * 2.0;
            origin -= spread;
            size += spread * 2.0;
        }
        float2 pixel = origin + corner * size;
        Fragment f;
        f.position = float4(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0, 0, 1);
        f.local = pixel - (q.rect.xy + q.rect.zw * 0.5);
        f.uv = (q.uv.xy + corner * q.uv.zw) / u.atlasSize;
        f.color = q.color;
        f.params = q.params;
        f.halfSize = q.rect.zw * 0.5;
        return f;
    }

    float roundedBox(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    fragment float4 board_fragment(Fragment f [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::nearest);
        float alpha = f.color.a;
        int kind = int(f.params.x);
        if (kind == 1) {
            alpha *= pow(atlas.sample(s, f.uv).r, 0.85);
        } else if (kind == 2) {
            float d = roundedBox(f.local, f.halfSize, f.params.y);
            alpha *= clamp(0.5 - d, 0.0, 1.0);
        } else if (kind == 3) {
            float d = roundedBox(f.local, f.halfSize, f.params.y);
            float softness = max(f.params.z, 1.0);
            alpha *= 1.0 - smoothstep(-softness * 0.5, softness * 2.0, d);
        }
        return float4(f.color.rgb * alpha, alpha);
    }
    """
}
