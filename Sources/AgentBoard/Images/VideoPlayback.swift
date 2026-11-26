import AVFoundation
import AppKit
import Orchestration
import QuartzCore

/// Where a video card's controls sit along the bottom of its picture, in the card's coordinates.
struct VideoControlsLayout {
    static let height: CGFloat = 32
    static let button: CGFloat = 24
    static let minimumWidthWithTime: CGFloat = 280

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
        // On a narrow card the time gives way, so the track keeps room to scrub.
        let showsTime = strip.width >= Self.minimumWidthWithTime
        time = CGRect(x: play.maxX + 6, y: mid - 8, width: showsTime ? 78 : 0, height: 16)
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
    /// The file this card last played, loaded or not.
    private var shownFile: String?
    private var duration: Double = 0
    private var layout = VideoControlsLayout(picture: .zero)
    private var scale: CGFloat = 2
    /// Where an unloaded video was, to come back to when it is on screen again.
    private var resumeAt: CMTime = .zero

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
        layer.backgroundColor = BoardPalette.rgb(Theme.Hex.window)
        strip.backgroundColor = BoardPalette.rgb(Theme.Hex.window, 0.72)
        strip.cornerRadius = CardMetrics.radius
        strip.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        track.backgroundColor = BoardPalette.rgb(Theme.Hex.white, 0.3)
        track.cornerRadius = Theme.Radius.thumb
        progress.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
        progress.cornerRadius = Theme.Radius.thumb
        progress.anchorPoint = .zero
        loopFill.backgroundColor = BoardPalette.rgb(BoardPalette.accent)
        loopFill.cornerRadius = Theme.Radius.control
        time.font = CardFrame.controlFont
        time.fontSize = CardFrame.controlFont.pointSize
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
        time.isHidden = layout.time.width == 0
        duration = record.duration ?? duration
        // Off the viewport the player lets go of its item: nothing loads or decodes.
        if !visible {
            if file != nil {
                resumeAt = file == record.file ? player.currentTime() : .zero
                player.pause()
                player.replaceCurrentItem(with: nil)
                file = nil
            }
            return refresh(at: resumeAt.seconds.nanToZero)
        }
        if file != record.file {
            if file != nil || shownFile != record.file { resumeAt = .zero }
            file = record.file
            shownFile = record.file
            let item = AVPlayerItem(url: ImageFiles.url(of: record.file, in: dataFolder))
            player.replaceCurrentItem(with: item)
            if let ended { NotificationCenter.default.removeObserver(ended) }
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
            if resumeAt != .zero { player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
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

    /// Keys on a focused video card: Space plays or pauses, M mutes, L loops, the arrows move
    /// 5 s. True when it took the key.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: togglePlay()
        case 123: step(-5)
        case 124: step(5)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m": player.isMuted.toggle()
            case "l": looping.toggle()
            default: return false
            }
        }
        refresh()
        return true
    }

    private func step(_ seconds: Double) {
        guard duration > 0 else { return }
        seek(to: min(max(player.currentTime().seconds.nanToZero + seconds, 0), duration) / duration)
    }

    /// The controls for VoiceOver: three buttons and the position as a slider. `screen` turns a
    /// rect in the picture's coordinates into screen coordinates.
    func accessibilityElements(parent: Any, name: String, screen: (CGRect) -> CGRect) -> [NSAccessibilityElement] {
        let now = player.currentTime().seconds.nanToZero
        let play = VideoAccessibilityControl(role: .button, label: isPlaying ? "Pause \(name)" : "Play \(name)",
                                             frame: screen(layout.play), parent: parent) { [weak self] in self?.togglePlay(); self?.refresh() }
        let mute = VideoAccessibilityControl(role: .button, label: player.isMuted ? "Turn sound on" : "Mute",
                                             frame: screen(layout.mute), parent: parent) { [weak self] in self?.player.isMuted.toggle(); self?.refresh() }
        let loop = VideoAccessibilityControl(role: .button, label: looping ? "Stop looping" : "Loop",
                                             frame: screen(layout.loop), parent: parent) { [weak self] in self?.looping.toggle(); self?.refresh() }
        let position = VideoAccessibilityControl(role: .slider, label: "Position in \(name)", frame: screen(layout.track), parent: parent) {}
        position.setAccessibilityValue("\(Self.clock(now)) of \(Self.clock(duration))")
        position.increment = { [weak self] in self?.step(5) }
        position.decrement = { [weak self] in self?.step(-5) }
        return [play, mute, loop, position]
    }

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
        loopGlyph.contents = CardIcon.symbol("repeat", color: white).image(size: 13, scale: scale)
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

/// One video control as VoiceOver sees it: pressing a button, or moving the position slider.
final class VideoAccessibilityControl: NSAccessibilityElement {
    private let press: () -> Void
    var increment: (() -> Void)?
    var decrement: (() -> Void)?

    init(role: NSAccessibility.Role, label: String, frame: CGRect, parent: Any, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        setAccessibilityFrame(frame)
        setAccessibilityParent(parent)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        increment?()
        return increment != nil
    }

    override func accessibilityPerformDecrement() -> Bool {
        decrement?()
        return decrement != nil
    }
}
