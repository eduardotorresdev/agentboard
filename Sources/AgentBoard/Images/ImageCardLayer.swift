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
        title = CGRect(x: CardFrame.titleX, y: height / 2 - 10, width: max(0, close.minX - CardFrame.titleX - 8), height: 20)
        picture = CGRect(x: 0, y: height, width: size.width, height: max(0, size.height - height))
    }
}

/// One image card: a title bar with its name and close control, the picture below it.
final class ImageCardLayer: CALayer {
    private let bar = CardTitleBar()
    private var focused = false
    private let closeHover = CALayer()
    private let closeGlyph = CATextLayer()
    private let picture = CALayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private var handlesVisible = false
    private var hoveredHandle: Int?
    private var shownFile: String?
    /// The player, for a video card.
    private(set) var video: VideoPlayback?

    override init() {
        super.init()
        picture.contentsGravity = .resize
        picture.masksToBounds = true
        picture.cornerRadius = CardMetrics.radius
        picture.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        picture.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.05)
        [bar, closeHover, closeGlyph, picture].forEach(addSublayer)
        CardFrame.reveal([closeGlyph], visible: false)
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

    @MainActor func update(frame: CGRect, record: ImageRecord, dataFolder: URL, focused: Bool, closeHovered: Bool, renaming: Bool, scale: CGFloat, visible: Bool = true) {
        self.frame = frame
        let layout = ImageCardLayout(size: frame.size)
        self.focused = focused
        CardFrame.style(self, focused: focused)
        // While renaming, a field covers the name.
        bar.update(size: bounds.size, height: ImageRecord.titleHeight, icon: .symbol(record.isVideo ? "film" : "photo", color: Theme.Hex.inkMuted), status: nil, title: renaming ? "" : record.name,
                   detail: nil, focused: focused, reserve: bounds.width - layout.title.maxX, scale: scale)
        CardFrame.closeButton(closeHover, closeGlyph, in: layout.close, hovered: closeHovered, scale: scale)
        picture.frame = layout.picture

        if record.isVideo {
            let video = video ?? {
                let made = VideoPlayback()
                addSublayer(made.layer)
                self.video = made
                return made
            }()
            video.update(picture: layout.picture, record: record, dataFolder: dataFolder, visible: visible, scale: scale)
            return
        }
        if shownFile != record.file {
            // The old picture is gone with its file.
            if let old = shownFile { Self.cache[old] = nil }
            shownFile = record.file
            let file = record.file
            Self.load(file, in: dataFolder) { [weak self] image in
                guard let self, self.shownFile == file else { return }
                if let image { Self.cache[file] = image }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.picture.contents = image
                CATransaction.commit()
            }
        }
    }

    // MARK: Loading

    /// Its card is gone: the picture leaves the cache.
    @MainActor func forget() {
        video?.invalidate()
        if let shownFile { Self.cache[shownFile] = nil }
        shownFile = nil
    }

    /// Loaded pictures by file name, only of cards that show them; a replaced picture has a new one.
    @MainActor static var cache: [String: CGImage] = [:]

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
        // A line's target lights up with the highlighted ring, like focus.
        CardFrame.style(self, focused: focused || linkTarget)
        CardFrame.reveal([closeGlyph], visible: visible || focused)
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
