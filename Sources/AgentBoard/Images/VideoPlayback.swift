import AVFoundation
import AppKit
import Orchestration
import QuartzCore

/// Where a video card's controls sit along the bottom of its picture, in the card's coordinates.
struct VideoControlsLayout {
    static let height: CGFloat = 32
    static let button: CGFloat = 24

    let strip: CGRect
    let play: CGRect
    let time: CGRect
    let track: CGRect
    let mute: CGRect
    let loop: CGRect

    init(picture: CGRect) {
        let height = min(Self.height, picture.height)
        strip = CGRect(x: picture.minX, y: picture.maxY - height, width: picture.width, height: height)
        let mid = strip.midY, size = Self.button
        play = CGRect(x: strip.minX + 6, y: mid - size / 2, width: size, height: size)
        loop = CGRect(x: strip.maxX - 6 - size, y: mid - size / 2, width: size, height: size)
        mute = loop.offsetBy(dx: -size - 2, dy: 0)
        time = CGRect(x: play.maxX + 6, y: mid - 8, width: 78, height: 16)
        track = CGRect(x: time.maxX + 6, y: mid - 3, width: max(0, mute.minX - time.maxX - 14), height: 6)
    }

    enum Control { case play, mute, loop, track }

    func control(at point: CGPoint) -> Control? {
        if play.contains(point) { return .play }
        if mute.contains(point) { return .mute }
        if loop.contains(point) { return .loop }
        // The track is thin; the whole band between time and mute seeks.
        if point.x >= track.minX - 4, point.x <= track.maxX + 4, strip.contains(point) { return .track }
        return nil
    }

    /// The fraction of the video at `x` along the track.
    func fraction(at x: CGFloat) -> Double {
        track.width > 0 ? Double(min(max((x - track.minX) / track.width, 0), 1)) : 0
    }
}

/// The player of one video card: an `AVPlayerLayer` over the picture area and a strip of
/// controls (play/pause, time, scrub track, mute, loop). It starts paused and muted, so it never
/// plays sound on its own; a paused player decodes nothing, and the board pauses it whenever
/// the card leaves the viewport.
@MainActor
final class VideoPlayback {
    let layer = AVPlayerLayer()
    private let strip = CALayer()
    private let playGlyph = CALayer()
    private let muteGlyph = CALayer()
    private let loopGlyph = CALayer()
    private let loopFill = CALayer()
    private let time = CATextLayer()
    private let track = CALayer()
    private let progress = CALayer()
    private let player = AVPlayer()
    private var observer: Any?
    private var ended: NSObjectProtocol?
    private(set) var file: String?
    private var duration: Double = 0
    private var layout = VideoControlsLayout(picture: .zero)
    private var scale: CGFloat = 2

    private(set) var looping = false
    var isPlaying: Bool { player.rate != 0 }

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        layer.player = player
        layer.videoGravity = .resizeAspect
        layer.masksToBounds = true
        layer.cornerRadius = CardMetrics.radius
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.backgroundColor = BoardPalette.rgb(BoardPalette.ink)
        strip.backgroundColor = BoardPalette.rgb(BoardPalette.ink, 0.72)
        strip.cornerRadius = CardMetrics.radius
        strip.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        track.backgroundColor = BoardPalette.rgb(Theme.Hex.white, 0.3)
        track.cornerRadius = 3
        progress.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
        progress.cornerRadius = 3
        progress.anchorPoint = .zero
        loopFill.backgroundColor = BoardPalette.rgb(BoardPalette.secondary)
        loopFill.cornerRadius = Theme.Radius.control
        time.font = CardFrame.controlFont
        time.fontSize = 11
        time.foregroundColor = BoardPalette.rgb(Theme.Hex.white)
        for glyph in [playGlyph, muteGlyph, loopGlyph] { glyph.contentsGravity = .center }
        [loopFill, playGlyph, muteGlyph, loopGlyph, time, track].forEach(strip.addSublayer)
        track.addSublayer(progress)
        layer.addSublayer(strip)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Stops the time observer; call when the card goes away.
    func invalidate() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
        player.replaceCurrentItem(with: nil)
    }

    /// Lays the player over `picture` (card coordinates) and loads `record`'s file when it changed.
    func update(picture: CGRect, record: ImageRecord, dataFolder: URL, visible: Bool, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.scale = scale
        layer.frame = picture
        layout = VideoControlsLayout(picture: CGRect(origin: .zero, size: picture.size))
        strip.frame = layout.strip
        let local = { (rect: CGRect) in rect.offsetBy(dx: -self.layout.strip.minX, dy: -self.layout.strip.minY) }
        playGlyph.frame = local(layout.play)
        muteGlyph.frame = local(layout.mute)
        loopGlyph.frame = local(layout.loop)
        loopFill.frame = local(layout.loop)
        time.frame = local(layout.time)
        track.frame = local(layout.track)
        time.contentsScale = scale
        if file != record.file {
            file = record.file
            duration = record.duration ?? 0
            let item = AVPlayerItem(url: ImageFiles.url(of: record.file, in: dataFolder))
            player.replaceCurrentItem(with: item)
            if let ended { NotificationCenter.default.removeObserver(ended) }
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
        }
        // Off the viewport nothing decodes.
        if !visible, isPlaying { player.pause() }
        refresh()
    }

    /// A click (card coordinates) on the controls; true when it hit one. A press on the track
    /// seeks there; `dragged` keeps scrubbing until the mouse goes up.
    func click(at point: CGPoint, picture: CGRect, dragged: (_ seek: @escaping (CGPoint) -> Void) -> Void) -> Bool {
        let point = CGPoint(x: point.x - picture.minX, y: point.y - picture.minY)
        guard let control = layout.control(at: point) else { return false }
        switch control {
        case .play: togglePlay()
        case .mute: player.isMuted.toggle()
        case .loop: looping.toggle()
        case .track:
            let wasPlaying = isPlaying
            player.pause()
            seek(to: layout.fraction(at: point.x))
            dragged { [weak self] point in
                guard let self else { return }
                self.seek(to: self.layout.fraction(at: point.x - picture.minX))
            }
            if wasPlaying { player.play() }
        }
        refresh()
        return true
    }

    func togglePlay() {
        if isPlaying { return player.pause() }
        // Played to the end: start over.
        if duration > 0, player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
        player.play()
    }

    func pause() { player.pause() }

    private func seek(to fraction: Double) {
        player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        refresh(at: duration * fraction)
    }

    private func reachedEnd() {
        guard looping else { return refresh() }
        player.seek(to: .zero)
        player.play()
    }

    private func refresh(at second: Double? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = max(0, second ?? player.currentTime().seconds.nanToZero)
        time.string = "\(Self.clock(now)) / \(Self.clock(duration))"
        progress.frame = CGRect(x: 0, y: 0, width: track.bounds.width * (duration > 0 ? min(now / duration, 1) : 0), height: track.bounds.height)
        let white = Theme.Hex.white
        playGlyph.contents = CardIcon.symbol(isPlaying ? "pause.fill" : "play.fill", color: white).image(size: 13, scale: scale)
        muteGlyph.contents = CardIcon.symbol(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", color: white).image(size: 13, scale: scale)
        loopGlyph.contents = CardIcon.symbol("repeat", color: looping ? Theme.Hex.ink : white).image(size: 13, scale: scale)
        for glyph in [playGlyph, muteGlyph, loopGlyph] { glyph.contentsScale = scale }
        loopFill.isHidden = !looping
        CATransaction.commit()
    }

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private extension Double {
    var nanToZero: Double { isFinite ? self : 0 }
}
