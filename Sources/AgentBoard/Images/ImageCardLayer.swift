import AppKit
import ImageIO
import Orchestration
import QuartzCore

/// Where things sit in an image card, in its own coordinates.
struct ImageCardLayout {
    let title: CGRect
    let close: CGRect
    let picture: CGRect

    init(size: CGSize) {
        let height = ImageRecord.titleHeight
        close = CGRect(x: size.width - CardMetrics.inset - CardMetrics.closeSize + 4, y: (height - CardMetrics.closeSize) / 2,
                       width: CardMetrics.closeSize, height: CardMetrics.closeSize)
        title = CGRect(x: CardMetrics.inset + 2, y: height / 2 - 9, width: max(0, close.minX - CardMetrics.inset - 10), height: 18)
        picture = CGRect(x: 0, y: height, width: size.width, height: max(0, size.height - height))
    }
}

/// One image card: a title bar with its name and close control, the picture below it.
final class ImageCardLayer: CALayer {
    private let title = CATextLayer()
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let picture = CALayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?
    private var shownFile: String?

    override init() {
        super.init()
        backgroundColor = BoardPalette.card
        cornerRadius = CardMetrics.radius
        shadowColor = BoardPalette.rgb(BoardPalette.ink)
        closeHover.cornerRadius = CardMetrics.closeSize / 2
        closeHover.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.08)
        for layer in [title, closeGlyph] {
            layer.fontSize = 12
            layer.truncationMode = .end
        }
        title.font = PostItCardLayout.titleFont
        closeGlyph.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeGlyph.string = "✕"
        closeGlyph.alignmentMode = .center
        picture.contentsGravity = .resize
        picture.masksToBounds = true
        picture.cornerRadius = CardMetrics.radius
        picture.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        picture.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.05)
        [title, closeHover, closeGlyph, picture].forEach(addSublayer)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: CardMetrics.handleSize, height: CardMetrics.handleSize)
            handle.cornerRadius = CardMetrics.handleSize / 2
            handle.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
            handle.borderColor = BoardPalette.card
            handle.borderWidth = 2
            handle.shadowColor = BoardPalette.rgb(BoardPalette.ink)
            handle.shadowOpacity = 0.18
            handle.shadowRadius = 3
            handle.shadowOffset = CGSize(width: 0, height: 1)
            handle.isHidden = true
            handle.zPosition = 10
            addSublayer(handle)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The picture as last loaded, for copying.
    var image: CGImage? { picture.contents.map { $0 as! CGImage } }

    @MainActor func update(frame: CGRect, record: ImageRecord, dataFolder: URL, focused: Bool, closeHovered: Bool, renaming: Bool, scale: CGFloat) {
        self.frame = frame
        let layout = ImageCardLayout(size: frame.size)
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: CardMetrics.radius, cornerHeight: CardMetrics.radius, transform: nil)
        shadowOpacity = focused ? 0.16 : 0.08
        shadowRadius = focused ? 14 : 8
        shadowOffset = CGSize(width: 0, height: focused ? 12 : 5)
        for layer in [title, closeGlyph] { layer.contentsScale = scale }

        let ink = BoardPalette.ink
        let line = PostItCardLayout.lineHeight(PostItCardLayout.titleFont) + 2
        title.string = record.name
        title.isHidden = renaming
        title.foregroundColor = BoardPalette.rgb(ink, focused ? 0.9 : 0.6)
        title.frame = CGRect(x: layout.title.minX, y: layout.title.midY - line / 2, width: layout.title.width, height: line)
        closeHover.frame = layout.close
        closeHover.isHidden = !closeHovered
        closeGlyph.foregroundColor = BoardPalette.rgb(ink, closeHovered ? 0.8 : 0.4)
        closeGlyph.frame = CGRect(x: layout.close.minX, y: layout.close.midY - line / 2, width: layout.close.width, height: line)
        picture.frame = layout.picture

        if shownFile != record.file {
            shownFile = record.file
            let file = record.file
            Self.load(file, in: dataFolder) { [weak self] image in
                guard let self, self.shownFile == file else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.picture.contents = image
                CATransaction.commit()
            }
        }
    }

    // MARK: Loading

    /// Loaded pictures by file name; a replaced picture has a new one.
    @MainActor private static var cache: [String: CGImage] = [:]

    /// The picture, decoded off the main thread at most 2048 px on its longer side.
    @MainActor private static func load(_ file: String, in dataFolder: URL, done: @escaping @MainActor (CGImage?) -> Void) {
        if let image = cache[file] { return done(image) }
        let url = ImageFiles.url(of: file, in: dataFolder)
        DispatchQueue.global(qos: .userInitiated).async {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 2048]
            let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            nonisolated(unsafe) let loaded = image
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let loaded { cache[file] = loaded }
                    done(loaded)
                }
            }
        }
    }

    // MARK: Handles, appearing

    func updateHandles(visible: Bool, hovered: Int?, linkTarget: Bool) {
        for (handle, point) in zip(handles, CardMetrics.handles(of: bounds)) { handle.position = point }
        if visible != handlesVisible {
            handlesVisible = visible
            for handle in handles {
                handle.isHidden = !visible
                if visible { handle.add(Self.spring("opacity", from: 0, to: 1, stiffness: 300, damping: 26), forKey: "appear") }
            }
        }
        if hovered != hoveredHandle {
            for (index, handle) in handles.enumerated() where index == hovered || index == hoveredHandle {
                let grow = index == hovered
                let scale: CGFloat = grow ? 1.4 : 1
                handle.add(Self.spring("transform.scale", from: handle.presentation()?.value(forKeyPath: "transform.scale") ?? (grow ? 1 : 1.4),
                                       to: scale, stiffness: 400, damping: 22), forKey: "scale")
                handle.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            hoveredHandle = hovered
        }
        if linkTarget {
            shadowColor = BoardPalette.rgb(BoardPalette.accent)
            shadowOpacity = 0.45
            shadowRadius = 18
            shadowOffset = .zero
        } else {
            shadowColor = BoardPalette.rgb(BoardPalette.ink)
        }
    }

    func animateAppearance() {
        add(Self.spring("opacity", from: 0, to: 1, stiffness: 240, damping: 24), forKey: "appear-fade")
        add(Self.spring("transform.translation.y", from: 14, to: 0, stiffness: 240, damping: 24), forKey: "appear-rise")
    }

    private static func spring(_ keyPath: String, from: Any?, to: Any, stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        return spring
    }
}
