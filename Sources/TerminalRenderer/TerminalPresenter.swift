import Metal

/// Renders terminals into targets: a terminal's own surface (a `CAMetalLayer` drawable, a
/// texture), or its region of a `SharedSurface`. All of a frame's terminals go in one command
/// buffer, with one render pass per target texture: a board drawing into a shared surface makes
/// one pass however many terminals changed.
public final class TerminalPresenter {
    public struct Target {
        public let layer: TerminalLayer
        public let texture: MTLTexture
        /// Top-left pixel of the terminal in `texture`.
        public let origin: SIMD2<Int>
        /// Presented after rendering, when drawing to the screen.
        public let drawable: MTLDrawable?

        public init(layer: TerminalLayer, texture: MTLTexture, origin: SIMD2<Int> = .zero, drawable: MTLDrawable? = nil) {
            self.layer = layer
            self.texture = texture
            self.origin = origin
            self.drawable = drawable
        }
    }

    public let device: MTLDevice
    public let pipeline: TerminalPipeline
    private let queue: MTLCommandQueue
    private let fill: MTLRenderPipelineState
    /// Layers' cell buffers are rewritten in place, so a frame waits for the previous one. It
    /// is checked, not signalled: a completion handler would wake a thread on every frame, and
    /// at a board's frame rates the previous frame is long done by the next.
    private var inFlight: MTLCommandBuffer?

    public init?(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let queue = device.makeCommandQueue(), let pipeline = TerminalPipeline(device: device, pixelFormat: pixelFormat),
              let library = try? device.makeLibrary(source: Self.fillSource, options: nil) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fill_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fill_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        guard let fill = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.fill = fill
    }

    /// Blocks until the GPU is done with the previous frame. Call before updating layers.
    public func beginFrame() {
        guard let previous = inFlight else { return }
        if previous.status != .completed && previous.status != .error { previous.waitUntilCompleted() }
        inFlight = nil
    }

    /// Paints each target's area with `background` and draws its terminal over it.
    @discardableResult
    public func render(_ targets: [Target], glyphs: GlyphCache, background: MTLClearColor) -> MTLCommandBuffer? {
        guard !targets.isEmpty, let commands = queue.makeCommandBuffer() else { return nil }
        inFlight = commands
        var color = SIMD4(Float(background.red), Float(background.green), Float(background.blue), Float(background.alpha))
        var passes: [ObjectIdentifier: [Target]] = [:]
        var order: [ObjectIdentifier] = []
        for target in targets {
            let key = ObjectIdentifier(target.texture)
            if passes[key] == nil { order.append(key) }
            passes[key, default: []].append(target)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        for key in order {
            let group = passes[key]!
            let texture = group[0].texture
            // A terminal filling its own texture is cleared; regions of a shared one keep
            // their neighbours and are painted one by one.
            let whole = group.count == 1 && group[0].origin == .zero && Self.size(of: group[0], glyphs) == (texture.width, texture.height)
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = whole ? .clear : .load
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            let viewport = SIMD2(Float(texture.width), Float(texture.height))
            for target in group {
                if !whole {
                    let size = Self.size(of: target, glyphs)
                    let x = min(max(target.origin.x, 0), texture.width), y = min(max(target.origin.y, 0), texture.height)
                    let rect = MTLScissorRect(x: x, y: y, width: min(size.0, texture.width - x), height: min(size.1, texture.height - y))
                    guard rect.width > 0, rect.height > 0 else { continue }
                    encoder.setScissorRect(rect)
                    encoder.setRenderPipelineState(fill)
                    encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                pipeline.encode(target.layer, glyphs: glyphs, origin: SIMD2(Float(target.origin.x), Float(target.origin.y)),
                                viewport: viewport, opacity: 1, into: encoder)
            }
            encoder.endEncoding()
            for target in group { if let drawable = target.drawable { commands.present(drawable) } }
        }
        commands.commit()
        return commands
    }

    private static func size(of target: Target, _ glyphs: GlyphCache) -> (Int, Int) {
        (target.layer.cols * glyphs.cellWidth, target.layer.rows * glyphs.cellHeight)
    }

    private static let fillSource = """
    #include <metal_stdlib>
    using namespace metal;
    // One triangle covering the target; the scissor rect limits it to a terminal's region.
    vertex float4 fill_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2.0 - 1.0, 0, 1);
    }
    fragment float4 fill_fragment(constant float4 &color [[buffer(0)]]) { return color; }
    """
}

extension TerminalTheme {
    /// The default background as an opaque clear color for a terminal's own surface.
    public var clearColor: MTLClearColor {
        MTLClearColor(red: Double(background & 0xFF) / 255, green: Double(background >> 8 & 0xFF) / 255,
                      blue: Double(background >> 16 & 0xFF) / 255, alpha: 1)
    }
}
