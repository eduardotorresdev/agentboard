import BenchKit
import CoreText
import Foundation
import QuartzCore
import TerminalCore
import TerminalRenderer

/// Renders the board's layer structure offscreen with Core Animation: a flipped root, cards,
/// and each card's terminal shown from its region of a SharedSurface, through one layer per
/// buffer as `BoardView` does. Checks placement and orientation without opening a window.
func renderLayers(to out: URL) {
    let scale: CGFloat = 2
    let offscreen = Offscreen(width: 1400, height: 700)
    let font = CTFontCreateWithName("Menlo" as CFString, 12 * scale, nil)
    let glyphs = GlyphCache(device: offscreen.device, font: font)!
    let presenter = TerminalPresenter(device: offscreen.device)!
    let surface = SharedSurface<Int>(device: offscreen.device)
    let theme = TerminalTheme.light
    let root = CALayer()
    root.isGeometryFlipped = true
    root.frame = CGRect(x: 0, y: 0, width: 700, height: 350)
    root.backgroundColor = CGColor(red: 0.9, green: 0.88, blue: 0.97, alpha: 1)
    var targets: [TerminalPresenter.Target] = []
    var shown: [(Int, Int, [CALayer])] = []
    var layers: [TerminalLayer] = []
    let texts = ["first card\r\nline two\r\n\u{1b}[1;35mbold violet\u{1b}[0m", "second card\r\n\u{1b}[43mhighlight\u{1b}[0m", "third card\r\nbottom row"]
    var sizes: [Int: (width: Int, height: Int)] = [:]
    let terminals = texts.enumerated().map { index, text -> TerminalCore.Terminal in
        let terminal = TerminalCore.Terminal(cols: [24, 18, 20][index], rows: 5)
        terminal.feed(text)
        return terminal
    }
    for (index, terminal) in terminals.enumerated() { sizes[index] = (terminal.cols * glyphs.cellWidth, terminal.rows * glyphs.cellHeight) }
    surface.arrange(sizes)
    for (index, terminal) in terminals.enumerated() {
        let card = CALayer()
        card.backgroundColor = .white
        card.cornerRadius = 10
        card.frame = CGRect(x: 20 + CGFloat(index) * 225, y: 20 + CGFloat(index) * 60, width: 215, height: 160)
        root.addSublayer(card)
        let content = CALayer()
        content.contentsScale = scale
        content.frame = CGRect(x: 8, y: 30, width: CGFloat(sizes[index]!.width) / scale, height: CGFloat(sizes[index]!.height) / scale)
        card.addSublayer(content)
        let buffers = (0..<2).map { _ in
            let buffer = CALayer()
            buffer.contentsScale = scale
            buffer.frame = content.bounds
            buffer.isHidden = true
            content.addSublayer(buffer)
            return buffer
        }
        let layer = TerminalLayer(device: offscreen.device)
        _ = layer.update(from: terminal, theme: theme, glyphs: glyphs)
        layers.append(layer)
        let target = surface.target(for: index)!
        targets.append(.init(layer: layer, texture: target.texture, origin: SIMD2(target.region.x, target.region.y)))
        shown.append((index, target.buffer, buffers))
    }
    presenter.render(targets, glyphs: glyphs, background: theme.clearColor)?.waitUntilCompleted()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, buffer, buffers) in shown { surface.show(index, from: buffer, on: buffers) }
    let clear = offscreen.queue.makeCommandBuffer()!
    clear.makeRenderCommandEncoder(descriptor: offscreen.pass)!.endEncoding()
    clear.commit()
    clear.waitUntilCompleted()
    // On our queue, so the read-back below runs after Core Animation's render.
    let renderer = CARenderer(mtlTexture: offscreen.texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                     kCARendererMetalCommandQueue: offscreen.queue])
    // The renderer's target is in pixels; the board is laid out in points. The tree is
    // committed after it joins the renderer, whose context only sees later commits.
    root.anchorPoint = .zero
    root.position = .zero
    root.transform = CATransform3DMakeScale(scale, scale, 1)
    renderer.layer = root
    renderer.bounds = CGRect(x: 0, y: 0, width: 1400, height: 700)
    CATransaction.commit()
    CATransaction.flush()
    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
    offscreen.writePNG(to: out, bottomUp: true)
}
