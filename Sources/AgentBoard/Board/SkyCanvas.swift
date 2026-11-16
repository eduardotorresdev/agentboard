import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The board's backdrop: a painted sky with drifting clouds, generated in Metal at a fraction of
/// the screen's resolution a few times a second.
/// It stays fixed while the board pans and zooms, like a painting hung behind the cards.
struct SkyCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> SkyView {
        let view = SkyView()
        // Card headers frost this sky: one blur per frame, shared by all of them, and none while
        // no header is on screen.
        view.onSkyFrame = { texture, commands in
            if SkyBlur.shared.isNeeded { SkyBlur.shared.encode(texture, commands) }
        }
        SkyBlur.shared.sky = view.sky
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
    /// The animated cloud layer, `skyScale` pixels per point.
    let sky = CAMetalLayer()
    /// Called with each new sky frame (drawn at a few frames a second) before it is presented,
    /// on the main thread: encode into `commands` to read `texture`, e.g. to blur it behind a card.
    var onSkyFrame: ((_ texture: MTLTexture, _ commands: MTLCommandBuffer) -> Void)?
    private var timer: Timer?
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
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = BoardPalette.rgb(Theme.Hex.accentSoft)
        // Two buffers are enough at a few frames a second, and a full-screen buffer costs megabytes.
        sky.maximumDrawableCount = 2
        sky.device = device
        sky.pixelFormat = .bgra8Unorm
        sky.framebufferOnly = false
        sky.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        layer?.addSublayer(sky)
        sky.isOpaque = true
        sky.magnificationFilter = .linear
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
        CATransaction.commit()
        tick()
    }

    // Drawn once the size settles: redrawing it on every step of a live resize would stall it.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        tick()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
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
        // A fixed epoch keeps the first frame of every launch different, never a still picture.
        draw(sky, pipeline: skyPipeline, pixels: bounds.size.applying(.init(scaleX: Self.skyScale, y: Self.skyScale)),
             pointsPerPixel: 1 / Self.skyScale, time: Float(skyTime + 40))
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
        image(["sky_fragment"], size: size, scale: scale, time: time)
    }

    /// `fragments` drawn in order into one image, each over the last with premultiplied alpha.
    private static func image(_ fragments: [String], size: CGSize, scale: CGFloat, time: Float = 40) -> CGImage? {
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
        for fragment in fragments {
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
            var uniforms = Uniforms(frame: SIMD4(Float(size.width), Float(size.height), time, Float(1 / scale)))
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

    // Tone laid in a few flat washes with soft seams, as watercolour dries in layers.
    static float washes(float x) {
        float f = saturate(x) * 3, i = floor(f);
        return (i + smoothstep(0.3, 0.7, f - i)) / 3;
    }

    // One bank of clouds painted over `color`: a firm edge where the bank faces the light (up),
    // a soft fade on its underside, white tops going blue toward the hollows. `marks` are the
    // brush's own tone changes, so no wash inside the bank is flat; pigment pools at its edge.
    static float3 cloud(float3 color, float2 p, float t, float seed, float scale, float threshold, float3 shade, float3 top, float marks) {
        float3 q = float3(p * scale + seed * float2(7.3, 3.1) + float2(t * 0.008, t * 0.002) * scale, t * 0.012 + seed);
        float n = fbm(q, 3) + (0.3 - billow(q * 2.2, 3)) * 0.3;
        float3 above = q - float3(0.03, 0.09, 0) * scale;
        float lit = n - fbm(above, 3) - (0.3 - billow(above * 2.2, 3)) * 0.3;
        float edge = mix(0.16, 0.045, smoothstep(-0.02, 0.04, lit));
        float tone = 0.55 + lit * 16 - (n - threshold) * 1.4 + marks;
        float3 body = mix(shade, top, washes(smoothstep(0.15, 0.85, tone)));
        float cover = smoothstep(threshold, threshold + edge, n);
        // A wet edge: a thin rim of the shade where the bank meets what's behind it.
        float rim = cover * (1 - smoothstep(threshold + edge, threshold + edge * 2.5, n)) * 0.35;
        return mix(color, mix(body, shade, rim), cover);
    }

    // A brush stroke's direction at p: mostly rising to the right, turning slowly across the canvas.
    static float2 strokeDirection(float2 p, float t) {
        float angle = -0.55 + (noise(float3(p * 0.6, t * 0.01 + 2)) - 0.5) * 1.6;
        return float2(cos(angle), sin(angle));
    }

    // Streaky noise along the stroke: long along it, thin across it, like bristle marks.
    static float bristles(float2 p, float2 d, float seed) {
        float2 q = float2(dot(p, d), dot(p, float2(-d.y, d.x)));
        return noise(float3(q * float2(3, 70), seed)) - 0.5;
    }

    fragment float4 sky_fragment(SkyVertex in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 p = uv * u.frame.xy / 760.0;
        float t = u.frame.z;

        // Every sample is dragged along the brush (fine bristles plus broad dabs), so edges
        // feather into strokes instead of fuzz.
        float2 dir = strokeDirection(p, t);
        float2 bp = p + dir * (bristles(p, dir, 11) * 0.028 + bristles(p * 0.3, dir, 3) * 0.035);

        // Composition, with wandering borders: open sky in the upper left, a bluer band at the bottom.
        float wander = noise(float3(p * 0.9, t * 0.007 + 3)) - 0.5;
        float open = smoothstep(0.6, 0.1, length(uv * float2(1.0, 1.5)) + wander * 0.5);
        float low = smoothstep(0.5, 0.85, uv.y + wander * 0.3);

        // Paint, not a gradient: a clear sky blue, a darker greener blue that pools low on the
        // canvas, a soft middle blue, pale and white, mixed unevenly as a painter would.
        float3 deep = float3(0.45, 0.74, 0.91), green = float3(0.44, 0.70, 0.79);
        float3 shade = float3(0.70, 0.86, 0.94), pale = float3(0.86, 0.94, 0.97), white = float3(0.97, 0.985, 1.0);
        float mixing = smoothstep(0.35, 0.65, fbm(float3(p * 0.8 + 11, t * 0.009), 3) + (uv.y - 0.5) * 0.4);
        float3 pigment = mix(deep, green, mixing);
        float3 shadow = mix(mix(shade, pale, 0.45), pigment, 0.1 + open * 0.5);
        // Brush marks: broad dabs plus streaks along the stroke, used to vary every wash.
        float dabs = (fbm(float3(bp * 4.5, t * 0.02 + 9), 3) - 0.5) * 1.1 + bristles(bp * 1.4, dir, 17) * 0.18;

        // Behind the clouds: pale washes everywhere, the clear blue only in the opening.
        float haze = fbm(float3(bp * 1.1 + float2(t * 0.006, 0), t * 0.01 + 7), 3) + dabs * 0.15;
        float3 color = mix(mix(mix(shade, pale, 0.5), white, washes(smoothstep(0.3, 0.6, haze))), mix(deep, shade, washes(smoothstep(0.45, 0.8, haze)) * 0.4), open);
        // Back to front: hazy far banks, then the big white masses.
        color = cloud(color, bp, t, 1, 1.1, 0.325 + open * 0.2, shadow, pale, dabs);
        color = cloud(color, bp, t, 2, 1.5, 0.375 + open * 0.2, shadow, white, dabs);
        color = cloud(color, bp, t, 3, 1.0, 0.385 + open * 0.2, mix(shade, pale, 0.7), white, dabs * 0.8);
        // Along the bottom: a greener blue haze and two ridges of low cloud, the nearer one darker.
        float2 flat = bp * float2(0.7, 1.5);
        float lowest = smoothstep(0.7, 0.95, uv.y + wander * 0.3);
        color = mix(color, mix(shade, green, 0.7), low * 0.8);
        color = cloud(color, flat, t, 4, 1.4, 0.76 - low * 0.36, mix(shade, green, 0.5), mix(pale, white, 0.4), dabs);
        color = cloud(color, flat, t, 5, 1.9, 0.86 - lowest * 0.42, green * float3(0.92, 0.96, 0.98), mix(shade, green, 0.3), dabs);
        // Uneven pigment over everything blue: patches where it pools deeper, patches left paler.
        float pool = fbm(float3(bp * 1.7 + 23, t * 0.012), 3) - 0.44 + dabs * 0.12;
        // The deepest tones stay where the painting keeps them: the opening and the bottom.
        float depth = 0.3 + 0.7 * max(open, low);
        float blue = saturate(1 - (color.r - 0.6) * 2.8);
        color = mix(color, pigment, smoothstep(0.03, 0.12, pool) * 0.6 * blue * depth);
        // Here and there a second, darker layer of the same pigment.
        color = mix(color, pigment * float3(0.84, 0.91, 0.95), smoothstep(0.13, 0.19, pool) * 0.5 * blue * depth);
        color = mix(color, pale, smoothstep(0.05, 0.14, -pool) * 0.3 * blue);
        return float4(saturate(color), 1);
    }
    """
}
