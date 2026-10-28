import Metal
import TerminalCore

/// Draws `TerminalLayer`s: one instanced draw per terminal, one instance per cell. The vertex
/// shader finds each cell through the row map and collapses empty cells to zero-area quads,
/// so blank space costs no fragment work.
public final class TerminalPipeline {
    private let pipeline: MTLRenderPipelineState

    /// Matches `CellUniforms` in the shader.
    private struct Uniforms {
        /// origin x, origin y, cell width, cell height (pixels)
        var frame: SIMD4<Float>
        /// viewport width, height, atlas width, height (pixels)
        var viewport: SIMD4<Float>
        /// opacity, underline y, line thickness, strikethrough y
        var style: SIMD4<Float>
        /// cols, rows, atlas slots per row
        var grid: SIMD4<UInt32>
    }

    /// `pixelFormat` of the target; blending is premultiplied alpha.
    public init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cell_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cell_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
    }

    /// Encodes `layer` with its top-left cell at `origin` (whole pixels).
    public func encode(_ layer: TerminalLayer, glyphs: GlyphCache, origin: SIMD2<Float>, viewport: SIMD2<Float>,
                       opacity: Float, into encoder: MTLRenderCommandEncoder) {
        guard let cells = layer.cells, let rowMap = layer.rowMap, layer.cols > 0, layer.rows > 0 else { return }
        let cellHeight = Float(glyphs.cellHeight)
        let thickness = max(1, (cellHeight / 17).rounded())
        var uniforms = Uniforms(
            frame: SIMD4(origin.x, origin.y, Float(glyphs.cellWidth), cellHeight),
            viewport: SIMD4(viewport.x, viewport.y, Float(glyphs.texture.width), Float(glyphs.texture.height)),
            style: SIMD4(opacity, (cellHeight * 0.84).rounded(), thickness, (cellHeight * 0.52).rounded()),
            grid: SIMD4(UInt32(layer.cols), UInt32(layer.rows), UInt32(glyphs.slotsPerRow), 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(cells, offset: 0, index: 0)
        encoder.setVertexBuffer(rowMap, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(glyphs.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: layer.cols * layer.rows)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Cell { uint glyph; uint fg; uint bg; uint flags; };
    struct CellUniforms { float4 frame; float4 viewport; float4 style; uint4 grid; };

    struct CellFragment {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float4 fg [[flat]];
        float4 bg [[flat]];
        uint flags [[flat]];
        uint glyph [[flat]];
    };

    constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

    vertex CellFragment cell_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    const device Cell *cells [[buffer(0)]],
                                    const device uint *rowMap [[buffer(1)]],
                                    constant CellUniforms &u [[buffer(2)]]) {
        uint cols = u.grid.x;
        uint col = iid % cols, row = iid / cols;
        Cell c = cells[rowMap[row] * cols + col];
        CellFragment f;
        f.fg = unpack_unorm4x8_to_float(c.fg);
        f.bg = unpack_unorm4x8_to_float(c.bg);
        f.flags = c.flags;
        f.glyph = c.glyph;
        f.uv = float2(0);
        f.local = float2(0);
        if (c.glyph == 0 && f.bg.a == 0 && c.flags == 0) {
            f.position = float4(-2, -2, 0, 1);  // nothing to draw: zero-area quad, no fragments
            return f;
        }
        float2 corner = corners[vid];
        float2 cell = u.frame.zw;
        float2 pixel = u.frame.xy + (float2(col, row) + corner) * cell;
        f.position = float4(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0, 0, 1);
        uint slot = c.glyph > 0 ? c.glyph - 1 : 0;
        f.uv = (float2(slot % u.grid.z, slot / u.grid.z) + corner) * cell;
        f.local = corner * cell;
        return f;
    }

    fragment float4 cell_fragment(CellFragment f [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                  constant CellUniforms &u [[buffer(0)]]) {
        constexpr sampler s(coord::pixel, filter::nearest);
        float coverage = f.glyph != 0 ? atlas.sample(s, f.uv).r : 0.0;  // curve baked into the atlas
        float y = f.local.y, line = u.style.y, t = u.style.z;
        bool onLine = y >= line && y < line + t;
        if ((f.flags & 1u) != 0 && onLine) coverage = 1;
        if ((f.flags & 2u) != 0 && (onLine || (y >= line - 2 * t && y < line - t))) coverage = 1;
        if ((f.flags & 4u) != 0 && onLine && fmod(floor(f.local.x / (2 * t)), 2.0) == 0) coverage = 1;
        if ((f.flags & 8u) != 0 && y >= u.style.w && y < u.style.w + t) coverage = 1;
        if ((f.flags & 16u) != 0 && y < t) coverage = 1;
        float a = coverage * f.fg.a;
        float4 color = float4(f.fg.rgb * a, a) + float4(f.bg.rgb * f.bg.a, f.bg.a) * (1.0 - a);
        return color * u.style.x;
    }
    """
}
