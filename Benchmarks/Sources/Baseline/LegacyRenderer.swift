import Metal
import MetalKit

/// One quad on the board, laid out to match `Quad` in `LegacyShaders.source`.
struct LegacyQuad {
    enum Kind: Float {
        case solid = 0, glyph = 1, rounded = 2, shadow = 3
    }

    var rect: SIMD4<Float>
    var uv: SIMD4<Float> = .zero
    var color: SIMD4<Float>
    var params: SIMD4<Float>

    init(_ kind: Kind, _ rect: SIMD4<Float>, color: SIMD4<Float>, uv: SIMD4<Float> = .zero,
         radius: Float = 0, softness: Float = 0) {
        self.rect = rect
        self.uv = uv
        self.color = color
        params = SIMD4(kind.rawValue, radius, softness, 0)
    }

    func offset(by delta: SIMD2<Float>, alpha: Float) -> LegacyQuad {
        var copy = self
        copy.rect.x += delta.x
        copy.rect.y += delta.y
        copy.color.w *= alpha
        return copy
    }
}

/// Draws the whole board in one instanced draw call.
final class LegacyRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var buffer: MTLBuffer?
    /// The quad buffer is reused, so wait for the previous frame before overwriting it.
    private let inFlight = DispatchSemaphore(value: 1)

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: LegacyShaders.source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "board_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "board_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// The original `draw(_:atlas:in:)`, retargeted from an MTKView drawable to an offscreen pass.
    func draw(_ quads: [LegacyQuad], atlas: LegacyAtlas, pass: MTLRenderPassDescriptor, viewport: SIMD2<Float>) -> MTLCommandBuffer? {
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        inFlight.wait()
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        if !quads.isEmpty {
            let length = quads.count * MemoryLayout<LegacyQuad>.stride
            if (buffer?.length ?? 0) < length {
                buffer = device.makeBuffer(length: max(length, (buffer?.length ?? 0) * 2), options: .storageModeShared)
            }
            if let buffer {
                quads.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
                var uniforms = SIMD4<Float>(viewport.x, viewport.y, Float(atlas.size), Float(atlas.size))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 1)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
            }
        }
        encoder.endEncoding()
        commands.commit()
        return commands
    }
}
