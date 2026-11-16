import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The board's backdrop: a painted sky on canvas, generated in Metal. Two layers: the sky with
/// its drifting clouds, drawn at a fraction of the screen's resolution a few times a second, and
/// the canvas weave over it, drawn at full resolution only when the size changes.
/// It stays fixed while the board pans and zooms, like a painting hung behind the cards.
struct SkyCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> SkyView {
        let view = SkyView()
        // Card headers frost this sky: one blur per frame, shared by all of them.
        view.onSkyFrame = { texture, commands in SkyBlur.shared.encode(texture, commands) }
        return view
    }
    func updateNSView(_ view: SkyView, context: Context) {}
}

final class SkyView: NSView {
    /// Sky pixels per point: the clouds are soft, so a quarter of the pixels of a 1x screen is enough.
    static let skyScale: CGFloat = 0.5
    /// Clouds move a few points a minute, so a handful of frames a second reads as continuous.
    private static let framesPerSecond: Double = 8
    /// With Reduce Motion the clouds still drift, this many times slower, one frame every few seconds.
    private static let reducedMotionSlowdown: Double = 8

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let skyPipeline: MTLRenderPipelineState?
    private let weavePipeline: MTLRenderPipelineState?
    private let squaresPipeline: MTLRenderPipelineState?
    /// The animated cloud layer, `skyScale` pixels per point.
    let sky = CAMetalLayer()
    /// Called with each new sky frame (drawn at a few frames a second) before it is presented,
    /// on the main thread: encode into `commands` to read `texture`, e.g. to blur it behind a card.
    var onSkyFrame: ((_ texture: MTLTexture, _ commands: MTLCommandBuffer) -> Void)?
    private let weave = CAMetalLayer()
    /// Twinkling squares over the sky, at one pixel per point; kept out of `sky` so blurs of it stay clean.
    private let squares = CAMetalLayer()
    private var timer: Timer?
    private var weaveSize: CGSize = .zero
    /// Seconds of sky time, advanced more slowly under Reduce Motion.
    private var skyTime: Double = 0
    private var lastTick = CACurrentMediaTime()

    /// Matches `SkyUniforms` in the shader.
    private struct Uniforms {
        /// size in points, time in seconds, points per pixel
        var frame: SIMD4<Float>
    }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        let library = device.flatMap { try? $0.makeLibrary(source: Self.source, options: nil) }
        func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
            guard let device, let library else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "sky_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        skyPipeline = pipeline("sky_fragment")
        weavePipeline = pipeline("weave_fragment")
        squaresPipeline = pipeline("squares_fragment")
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = CGColor(srgbRed: 0.84, green: 0.89, blue: 0.95, alpha: 1)
        for metal in [sky, weave, squares] {
            metal.device = device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = metal !== sky
            metal.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            layer?.addSublayer(metal)
        }
        sky.isOpaque = true
        sky.magnificationFilter = .linear
        weave.isOpaque = false
        squares.isOpaque = false
        squares.magnificationFilter = .nearest
        NotificationCenter.default.addObserver(self, selector: #selector(tick), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.frame = bounds
        weave.frame = bounds
        squares.frame = bounds
        CATransaction.commit()
        tick()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        weaveSize = .zero
        tick()
    }

    private var isShown: Bool {
        guard let window else { return false }
        #if BENCH
        if BenchScenario.background { return true }
        #endif
        return window.occlusionState.contains(.visible)
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let elapsed = now - lastTick
        // Under Reduce Motion: one frame every few seconds, the drift itself much slower.
        if reduced && elapsed < 3 && skyTime > 0 { return }
        skyTime += reduced ? elapsed / Self.reducedMotionSlowdown : elapsed
        lastTick = now
        guard isShown, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        if weaveSize != bounds.size {
            weaveSize = bounds.size
            weave.contentsScale = scale
            draw(weave, pipeline: weavePipeline, pixels: bounds.size.applying(.init(scaleX: scale, y: scale)), pointsPerPixel: 1 / scale)
        }
        // A fixed epoch keeps the first frame of every launch different, never a still picture.
        draw(sky, pipeline: skyPipeline, pixels: bounds.size.applying(.init(scaleX: Self.skyScale, y: Self.skyScale)),
             pointsPerPixel: 1 / Self.skyScale, time: Float(skyTime + 40))
        // Under Reduce Motion the squares hold still.
        draw(squares, pipeline: squaresPipeline, pixels: bounds.size, pointsPerPixel: 1, time: reduced ? 40 : Float(skyTime + 40))
    }

    private func draw(_ target: CAMetalLayer, pipeline: MTLRenderPipelineState?, pixels: CGSize, pointsPerPixel: CGFloat, time: Float = 0) {
        let pixels = CGSize(width: max(1, pixels.width.rounded()), height: max(1, pixels.height.rounded()))
        if target.drawableSize != pixels { target.drawableSize = pixels }
        guard let pipeline, let queue, let drawable = target.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(frame: SIMD4(Float(bounds.width), Float(bounds.height), time, Float(pointsPerPixel)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if target === sky { onSkyFrame?(drawable.texture, commands) }
        commands.present(drawable)
        commands.commit()
    }

    /// The backdrop as the app shows it, for screenshots: window captures (`cacheDisplay`,
    /// `ImageRenderer`) can't see Metal layers and show only the plain fill. `size` is in points;
    /// draw it under the captured window.
    static func snapshot(size: CGSize, scale: CGFloat = 2, time: Float = 40) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: source, options: nil), let commands = queue.makeCommandBuffer() else { return nil }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard width > 0, height > 0, let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        // The three layers in order, each over the last with premultiplied alpha.
        for (fragment, pointsPerPixel) in [("sky_fragment", 1 / skyScale), ("weave_fragment", 1 / scale), ("squares_fragment", 1)] {
            let pipeline = MTLRenderPipelineDescriptor()
            pipeline.vertexFunction = library.makeFunction(name: "sky_vertex")
            pipeline.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = pipeline.colorAttachments[0]!
            attachment.pixelFormat = .rgba8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            guard let state = try? device.makeRenderPipelineState(descriptor: pipeline) else { return nil }
            var uniforms = Uniforms(frame: SIMD4(Float(size.width), Float(size.height), time, Float(pointsPerPixel)))
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SkyUniforms { float4 frame; };
    struct SkyVertex { float4 position [[position]]; float2 uv; };

    // One triangle covering the screen; uv runs 0...1 with y down.
    vertex SkyVertex sky_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        SkyVertex out;
        out.position = float4(p * 2 - 1, 0, 1);
        out.uv = float2(p.x, 1 - p.y);
        return out;
    }

    static float hash(float3 p) {
        p = fract(p * 0.3183099 + 0.1);
        p *= 17.0;
        return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    static float noise(float3 x) {
        float3 i = floor(x), f = fract(x);
        f = f * f * (3 - 2 * f);
        return mix(mix(mix(hash(i), hash(i + float3(1, 0, 0)), f.x),
                       mix(hash(i + float3(0, 1, 0)), hash(i + float3(1, 1, 0)), f.x), f.y),
                   mix(mix(hash(i + float3(0, 0, 1)), hash(i + float3(1, 0, 1)), f.x),
                       mix(hash(i + float3(0, 1, 1)), hash(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    static float fbm(float3 p, int octaves) {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            sum += amplitude * noise(p);
            p = float3(p.xy * 2.03 + float2(17.1, 3.7), p.z * 1.6);
            amplitude *= 0.5;
        }
        return sum;
    }

    // Short dabs along a gently turning direction: the marks of a brush.
    static float strokes(float2 p, float seed) {
        float angle = 0.6 + (noise(float3(p * 0.35, seed)) - 0.5) * 3.5;
        float2 d = float2(cos(angle), sin(angle));
        float2 q = float2(dot(p, d), dot(p, float2(-d.y, d.x)));
        return (noise(float3(q * float2(7, 26), seed + 3)) - 0.5)
             + 0.6 * (noise(float3(q * float2(14, 55), seed + 7)) - 0.5);
    }

    // Rounded, piled-up noise: the puffs of a cumulus.
    static float billow(float3 p, int octaves) {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            sum += amplitude * abs(noise(p) * 2 - 1);
            p = float3(p.xy * 2.07 + float2(5.3, 11.9), p.z * 1.5);
            amplitude *= 0.5;
        }
        return sum;
    }

    // How much cloud there is at p: big masses built of puffs, warped so they swirl as they drift.
    static float cloud(float2 p, float t) {
        float2 w = p + float2(t * 0.0045, t * 0.0012);
        float3 c = float3(w * 0.8, t * 0.006);
        float2 warp = float2(fbm(c + float3(1.7, 9.2, 0), 3), fbm(c + float3(8.3, 2.8, 0), 3)) - 0.5;
        float masses = fbm(float3(w * 0.45 + warp * 0.3, t * 0.004 + 4), 3);
        float puffs = billow(float3(w * 1.05 + warp * 0.6, t * 0.01), 4);
        return masses * 1.6 + puffs * 0.9 - 0.93;
    }

    fragment float4 sky_fragment(SkyVertex in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float2 p = in.uv * u.frame.xy / 520.0;
        float t = u.frame.z;

        // Blue ground, painted: patches of deeper and paler blue, brush marks across them.
        float tone = fbm(float3(p * 1.1, 1), 4);
        float3 deep = float3(0.15, 0.40, 0.68), mid = float3(0.25, 0.53, 0.79), pale = float3(0.50, 0.69, 0.86);
        float3 sky = mix(deep, mid, smoothstep(0.30, 0.62, tone));
        sky = mix(sky, pale, smoothstep(0.55, 0.85, fbm(float3(p * 1.8 + 5, 2), 4)) * 0.5);
        sky += strokes(p, 11) * 0.03;

        // Clouds: cream where the light falls (from the upper left), warm gray in their hollows.
        float d = cloud(p, t);
        float lit = d - cloud(p + float2(0.06, 0.09), t);
        float cover = smoothstep(-0.03, 0.12, d);
        float3 shadow = float3(0.62, 0.63, 0.63), cream = float3(0.98, 0.95, 0.85);
        float3 body = mix(shadow, cream, saturate(0.5 + lit * 4 + d * 1.2 - 0.1));
        body += strokes(p * 0.8 + 2, 23) * 0.045;
        // Thin edges let the blue through, as a dry brush does.
        float3 color = mix(sky, body, cover * (0.7 + 0.3 * saturate(d * 6)));
        // Thinned to a pale wash: a backdrop that never competes with the cards.
        color = mix(float3(0.955, 0.97, 0.99), color, 0.16);
        return float4(saturate(color), 1);
    }

    // What stays put on the canvas, at full resolution: an over-and-under weave of slightly uneven
    // threads, and the fine marks the brush left in the paint.
    fragment float4 weave_fragment(SkyVertex in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float2 pt = in.uv * u.frame.xy;
        float2 g = pt / 2.4;
        float2 cell = floor(g), f = fract(g);
        float warp = sin(f.x * 3.14159) * (0.8 + 0.4 * hash(float3(cell.x, 0, 1)));
        float weft = sin(f.y * 3.14159) * (0.8 + 0.4 * hash(float3(0, cell.y, 2)));
        bool warpOnTop = fmod(cell.x + cell.y, 2.0) < 1.0;
        float yarn = warpOnTop ? warp : weft;
        float light = (yarn - 0.55) * 0.5 + (hash(float3(cell, 3)) - 0.5) * 0.12;
        float2 p = pt / 520.0;
        light += strokes(p * 1.6, 31) * 0.55 + strokes(p * 4.0, 47) * 0.25;
        float highlight = saturate(light) * 0.09, shade = saturate(-light) * 0.07;
        // Premultiplied: cream light on the ridges, a blue-gray shade in the furrows.
        return float4(float3(1.0, 0.98, 0.94) * highlight + float3(0.20, 0.26, 0.38) * shade, highlight + shade);
    }

    // Small squares on a fixed 6-point grid, lit in clusters that swell, fade and drift with the
    // clouds' wind; inside a cluster each square twinkles on its own slow clock.
    fragment float4 squares_fragment(SkyVertex in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float2 pt = in.uv * u.frame.xy;
        float2 cell = floor(pt / 6.0), f = fract(pt / 6.0);
        if (f.x > 0.67 || f.y > 0.67) return float4(0);
        float t = u.frame.z;
        float2 p = cell * 6.0 / 520.0 + float2(t * 0.0045, t * 0.0012);
        float cluster = smoothstep(0.56, 0.70, fbm(float3(p * 2.2, t * 0.02), 3));
        float phase = t * 0.35 + hash(float3(cell, 5)) * 9.0, k = floor(phase);
        float twinkle = mix(hash(float3(cell, k)), hash(float3(cell, k + 1)), smoothstep(0.0, 1.0, phase - k));
        float alpha = cluster * smoothstep(0.35, 0.85, twinkle) * 0.11;
        return float4(float3(0.42, 0.58, 0.82) * alpha, alpha);
    }
    """
}
