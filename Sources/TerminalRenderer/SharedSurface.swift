import CoreGraphics
import IOSurface
import Metal
import QuartzCore

/// One drawing surface shared by a board's visible terminals, so a frame draws every terminal
/// that changed in one render pass instead of one pass and one drawable per terminal.
///
/// Each terminal owns a region, the same in two buffers. A terminal is drawn into the buffer it
/// is *not* showing, then shown from it: the window server never reads a region while the GPU
/// writes it. The buffers are IOSurfaces, which Core Animation layers show directly (`contents`
/// plus `contentsRect`), so nothing is copied and nothing is presented.
public final class SharedSurface<ID: Hashable> {
    public struct Region: Equatable {
        public let x: Int, y: Int, width: Int, height: Int
    }

    public struct Buffer {
        public let surface: IOSurfaceRef
        public let texture: MTLTexture
    }

    public let device: MTLDevice
    public private(set) var buffers: [Buffer] = []
    public private(set) var regions: [ID: Region] = [:]
    /// The buffer each terminal is showing from.
    private var shown: [ID: Int] = [:]
    private var width = 0, height = 0
    /// Shelf packing: terminals are placed left to right on shelves, top to bottom.
    private var shelfX = 0, shelfY = 0, shelfHeight = 0

    public init(device: MTLDevice) {
        self.device = device
    }

    public var byteCount: Int { buffers.count * width * height * 4 }

    /// Places every terminal of the given pixel size. Terminals keep their region while their
    /// size doesn't change; returns the ones that must be drawn again (new, resized, or all of
    /// them when the buffers had to grow).
    @discardableResult
    public func arrange(_ sizes: [ID: (width: Int, height: Int)]) -> Set<ID> {
        for id in regions.keys where sizes[id] == nil {
            regions[id] = nil
            shown[id] = nil
        }
        guard !sizes.isEmpty else {
            release()
            return []
        }
        var placed = Set<ID>()
        for (id, size) in sizes {
            if let region = regions[id], region.width == size.width, region.height == size.height { continue }
            guard let region = place(width: size.width, height: size.height) else { return repack(sizes) }
            regions[id] = region
            shown[id] = nil
            placed.insert(id)
        }
        return placed
    }

    /// Where to draw `id` next: the buffer it isn't showing, and its region there.
    public func target(for id: ID) -> (buffer: Int, texture: MTLTexture, region: Region)? {
        guard let region = regions[id], buffers.count == 2 else { return nil }
        let buffer = 1 - (shown[id] ?? 1)
        return (buffer, buffers[buffer].texture, region)
    }

    /// Records that `id` is now shown from `buffer`; returns what its layer should show.
    public func show(_ id: ID, from buffer: Int) -> (surface: IOSurfaceRef, contentsRect: CGRect)? {
        guard let region = regions[id], buffer < buffers.count else { return nil }
        shown[id] = buffer
        let rect = CGRect(x: Double(region.x) / Double(width), y: Double(region.y) / Double(height),
                          width: Double(region.width) / Double(width), height: Double(region.height) / Double(height))
        return (buffers[buffer].surface, rect)
    }

    /// Records that `id` is now shown from `buffer` and makes `layers[buffer]` show it, hiding
    /// the other one. Call once the GPU finished drawing it, inside a transaction without
    /// implicit animations.
    ///
    /// Each buffer has its own layer, which keeps showing it: a frame flips which layer is
    /// hidden instead of handing the window server a surface again, which costs several times
    /// more on commit.
    public func show(_ id: ID, from buffer: Int, on layers: [CALayer]) {
        guard layers.count == 2, let (surface, rect) = show(id, from: buffer) else { return }
        let layer = layers[buffer], other = layers[1 - buffer]
        // Only what changed is set: every property set goes to the window server on commit.
        if (layer.contents as AnyObject?) !== surface { layer.contents = surface }
        if layer.contentsRect != rect { layer.contentsRect = rect }
        if layer.isHidden { layer.isHidden = false }
        if !other.isHidden { other.isHidden = true }
        // After a repack the hidden layer may still hold an old buffer: let it go.
        if let held = other.contents as AnyObject?, held !== buffers[1 - buffer].surface { other.contents = nil }
    }

    public func release() {
        buffers.removeAll()
        regions.removeAll()
        shown.removeAll()
        width = 0
        height = 0
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
    }

    private func place(width w: Int, height h: Int) -> Region? {
        guard !buffers.isEmpty, w <= width else { return nil }
        if shelfX + w > width {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + h <= height else { return nil }
        let region = Region(x: shelfX, y: shelfY, width: w, height: h)
        shelfX += w
        shelfHeight = max(shelfHeight, h)
        return region
    }

    /// Lays every terminal out afresh in new buffers of just the size they need. The old
    /// buffers stay alive while layers still show them.
    private func repack(_ sizes: [ID: (width: Int, height: Int)]) -> Set<ID> {
        // Every Apple GPU Metal runs on takes 16384-pixel textures.
        let limit = 16384
        let widest = sizes.values.map(\.width).max() ?? 1
        // Try shelves of 1…n terminals across and keep the layout with the least area.
        var best: (width: Int, height: Int)?
        let ordered = sizes.sorted { $0.value.height > $1.value.height }
        for across in 1...sizes.count {
            let candidate = min(limit, max(widest, ordered.prefix(across).map(\.value.width).reduce(0, +)))
            let used = Self.shelfHeight(ordered.map(\.value), width: candidate)
            if let current = best, current.width * current.height <= candidate * used { continue }
            best = (candidate, used)
        }
        guard let best else { return [] }
        let previous = (buffers, regions)
        release()
        // No spare room: memory is the point. A terminal that grows or appears repacks.
        width = best.width
        height = min(limit, best.height)
        buffers = (0..<2).compactMap { _ in makeBuffer(width: width, height: height) }
        guard buffers.count == 2 else {
            (buffers, regions) = previous
            return []
        }
        for (id, size) in ordered {
            guard let region = place(width: size.width, height: size.height) else { continue }
            regions[id] = region
        }
        return Set(regions.keys)
    }

    private static func shelfHeight(_ sizes: [(width: Int, height: Int)], width: Int) -> Int {
        var x = 0, y = 0, shelf = 0
        for size in sizes {
            if x + size.width > width {
                y += shelf
                x = 0
                shelf = 0
            }
            x += size.width
            shelf = max(shelf, size.height)
        }
        return y + shelf
    }

    private func makeBuffer(width: Int, height: Int) -> Buffer? {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241,  // 'BGRA'
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, CGColorSpace.sRGB)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
        return Buffer(surface: surface, texture: texture)
    }
}
