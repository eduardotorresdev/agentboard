import CoreText
import Metal
import QuartzCore
import Testing
import TerminalCore
import TerminalRenderer

struct SharedSurfaceTests {
    private let device = MTLCreateSystemDefaultDevice()!

    @Test func regionsStayPutWhileSizesDoNot() {
        let surface = SharedSurface<Int>(device: device)
        #expect(surface.arrange([1: (100, 50), 2: (80, 50)]) == [1, 2])
        let first = surface.regions
        // Same sizes: nothing moves, nothing to redraw.
        #expect(surface.arrange([1: (100, 50), 2: (80, 50)]).isEmpty)
        #expect(surface.regions == first)
        // One resized: only it is placed again; its neighbour keeps its region.
        let changed = surface.arrange([1: (100, 50), 2: (90, 50)])
        #expect(changed == [2] || changed == [1, 2])
        if changed == [2] { #expect(surface.regions[1] == first[1]) }
        // Regions never overlap.
        let regions = Array(surface.regions.values)
        for a in regions.indices {
            for b in regions.indices where a < b {
                let r = regions[a], s = regions[b]
                #expect(r.x + r.width <= s.x || s.x + s.width <= r.x || r.y + r.height <= s.y || s.y + s.height <= r.y)
            }
        }
    }

    @Test func drawsIntoTheBufferNotShown() throws {
        let surface = SharedSurface<Int>(device: device)
        surface.arrange([1: (100, 50)])
        let first = try #require(surface.target(for: 1))
        _ = surface.show(1, from: first.buffer)
        let second = try #require(surface.target(for: 1))
        #expect(second.buffer != first.buffer)
    }

    /// A frame flips which of the two layers is visible; each keeps its buffer, and a repack
    /// lets go of the old ones.
    @Test func showFlipsBetweenOneLayerPerBuffer() throws {
        let surface = SharedSurface<Int>(device: device)
        surface.arrange([1: (100, 50)])
        let layers = [CALayer(), CALayer()]
        for frame in 0..<4 {
            let target = try #require(surface.target(for: 1))
            surface.show(1, from: target.buffer, on: layers)
            #expect(!layers[target.buffer].isHidden && layers[1 - target.buffer].isHidden, "frame \(frame)")
            #expect((layers[target.buffer].contents as AnyObject?) === surface.buffers[target.buffer].surface)
        }
        #expect((layers[0].contents as AnyObject?) !== (layers[1].contents as AnyObject?))
        // Growing past the buffers repacks into new ones: the hidden layer drops the old buffer.
        surface.arrange([1: (100, 50), 2: (4000, 3000)])
        let target = try #require(surface.target(for: 1))
        surface.show(1, from: target.buffer, on: layers)
        #expect((layers[target.buffer].contents as AnyObject?) === surface.buffers[target.buffer].surface)
        #expect(layers[1 - target.buffer].contents == nil)
    }

    @Test func emptyBoardReleasesTheBuffers() {
        let surface = SharedSurface<Int>(device: device)
        surface.arrange([1: (100, 50)])
        #expect(surface.byteCount > 0)
        surface.arrange([:])
        #expect(surface.byteCount == 0)
    }

    /// Two terminals in one shared buffer: drawing one leaves the other's pixels alone.
    @Test func drawingOneTerminalKeepsItsNeighbour() throws {
        let glyphs = try #require(GlyphCache(device: device, font: CTFontCreateWithName("Menlo" as CFString, 24, nil)))
        let presenter = try #require(TerminalPresenter(device: device))
        let theme = TerminalTheme.light
        let terminals = [Terminal(cols: 8, rows: 2), Terminal(cols: 8, rows: 2)]
        terminals[0].feed("AAAA")
        terminals[1].feed("BBBB")
        let layers = terminals.map { _ in TerminalLayer(device: device) }
        let surface = SharedSurface<Int>(device: device)
        let size = (8 * glyphs.cellWidth, 2 * glyphs.cellHeight)
        surface.arrange([0: size, 1: size])

        func draw(_ ids: [Int]) throws -> Int {
            presenter.beginFrame()
            var targets: [TerminalPresenter.Target] = []
            var buffer = 0
            for id in ids {
                _ = layers[id].update(from: terminals[id], theme: theme, glyphs: glyphs)
                let target = try #require(surface.target(for: id))
                buffer = target.buffer
                targets.append(.init(layer: layers[id], texture: target.texture, origin: SIMD2(target.region.x, target.region.y)))
            }
            presenter.render(targets, glyphs: glyphs, background: theme.clearColor)?.waitUntilCompleted()
            for id in ids { _ = surface.show(id, from: buffer) }
            return buffer
        }
        func pixels(_ id: Int, buffer: Int) -> [UInt8] {
            let region = surface.regions[id]!
            var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
            surface.buffers[buffer].texture.getBytes(&bytes, bytesPerRow: region.width * 4,
                                                     from: MTLRegionMake2D(region.x, region.y, region.width, region.height), mipmapLevel: 0)
            return bytes
        }

        let both = try draw([0, 1])
        let neighbour = pixels(1, buffer: both)
        #expect(Set(neighbour).count > 2)  // text, not a flat fill
        terminals[0].feed("\rZZZZ")
        let next = try draw([0])
        #expect(next != both)
        #expect(pixels(1, buffer: both) == neighbour)
        #expect(pixels(0, buffer: next) != pixels(0, buffer: both))
    }
}
