import AgentRuntime
import AVFoundation
import SwiftUI

extension Element: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A browser or simulator on the canvas: a still tile (a title bar and its kind), so a board at
/// rest streams nothing; the live picture is one tap away, full screen.
struct ElementTile: View {
    let element: Element

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: element.symbol).foregroundStyle(Theme.inkMuted)
                Text(element.name).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.label)
            .padding(.horizontal, 12).frame(height: 32)
            .background(.ultraThinMaterial)
            ZStack {
                Theme.surfaceDeep
                VStack(spacing: 8) {
                    Image(systemName: element.symbol).font(Theme.Font.title).foregroundStyle(Theme.inkMuted)
                    Text("Tap to watch and drive it").font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension Element {
    var symbol: String { kind == "browser" ? "globe" : "iphone" }
}

/// One element's live stream, full screen: the picture as the Mac's card shows it, driven by
/// touch; text typed below goes to it as keys.
struct StreamPage: View {
    let link: HostLink
    let element: Element
    @State private var model = StreamModel()
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.surfaceDeep
                StreamSurface(model: model)
                if let notice = model.notice {
                    Text(notice).font(Theme.Font.body).foregroundStyle(Theme.inkMuted).padding()
                }
            }
            HStack(spacing: 8) {
                TextField("Type into it", text: $text)
                    .textFieldStyle(.plain).font(Theme.Font.body)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(Theme.Font.label) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(12)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
        }
        .background(Theme.surface.ignoresSafeArea())
        .navigationTitle(element.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if element.kind == "simulator" {
                Button { model.client?.send(["type": "button", "name": "home"]) } label: { Image(systemName: "house") }
                    .accessibilityLabel("Home")
            }
        }
        .task { await model.watch(element.id, on: link) }
        .onDisappear { model.stop() }
    }

    private func send() {
        if !text.isEmpty { model.client?.send(["type": "text", "text": text]) }
        model.client?.send(["type": "key", "key": "Enter"])
        text = ""
    }
}

/// The stream's connection and what it shows; frames reach the surface off the main thread.
@MainActor @Observable final class StreamModel {
    private(set) var notice: String? = "Connecting…"
    @ObservationIgnored private(set) var client: StreamClient?
    @ObservationIgnored let surface = StreamSurfaceView()
    @ObservationIgnored private var stopped = false

    func watch(_ card: UUID, on link: HostLink) async {
        while !stopped {
            guard let client = await link.openStream(card) else {
                notice = "This card isn't streaming right now."
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            if stopped { return client.close() }
            self.client = client
            surface.client = client
            let ended = AsyncStream<Void> { continuation in
                let surface = surface
                let decoder = Locked(StreamDecoder())
                client.onOut = { [weak self] out in
                    var picture: StreamDecoder.Picture?
                    decoder.mutate { picture = $0.decode(out) }
                    guard let picture else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if case .header = picture {} else if self?.notice != nil { self?.notice = nil }
                            surface.show(picture) { decoder.mutate { $0.restart() } }
                        }
                    }
                }
                client.onClose = { continuation.finish() }
            }
            for await _ in ended {}
            // Dropped: the last picture stays while a new ticket and channel come.
            self.client = nil
        }
    }

    func stop() {
        stopped = true
        client?.close()
    }
}

struct StreamSurface: UIViewRepresentable {
    let model: StreamModel
    func makeUIView(context: Context) -> StreamSurfaceView { model.surface }
    func updateUIView(_ view: StreamSurfaceView, context: Context) {}
}

/// Shows H.264 samples or JPEG frames aspect-fit, and turns touches into the stream's input:
/// one finger touches, two scroll.
final class StreamSurfaceView: UIView {
    weak var client: StreamClient?
    private let video = AVSampleBufferDisplayLayer()
    private let still = CALayer()
    private var header: StreamWire.Header?
    private var lastScroll: CGPoint?
    private var lastMove = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        video.videoGravity = .resizeAspect
        still.contentsGravity = .resizeAspect
        layer.addSublayer(still)
        layer.addSublayer(video)
        isMultipleTouchEnabled = true
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        addGestureRecognizer(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        still.frame = bounds
        CATransaction.commit()
    }

    /// `failed`: the layer gave up on the video; the decoder then waits for a keyframe.
    func show(_ picture: StreamDecoder.Picture, failed: () -> Void) {
        switch picture {
        case .header(let next): header = next
        case .image(let image):
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            still.contents = image
            CATransaction.commit()
        case .sample(let sample):
            if video.sampleBufferRenderer.status == .failed {
                video.sampleBufferRenderer.flush()
                failed()
                return
            }
            video.sampleBufferRenderer.enqueue(sample)
        }
    }

    /// Where a view point lands in the stream's input space, nil outside the picture.
    nonisolated static func map(_ point: CGPoint, in bounds: CGSize, to space: CGSize) -> CGPoint? {
        guard space.width > 0, space.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / space.width, bounds.height / space.height)
        let origin = CGPoint(x: (bounds.width - space.width * scale) / 2, y: (bounds.height - space.height * scale) / 2)
        let mapped = CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
        guard mapped.x >= 0, mapped.y >= 0, mapped.x <= space.width, mapped.y <= space.height else { return nil }
        return mapped
    }

    private func mapped(_ point: CGPoint) -> CGPoint? {
        guard let header else { return nil }
        return Self.map(point, in: bounds.size, to: CGSize(width: header.width, height: header.height))
    }

    private func touch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
        guard event?.allTouches?.count ?? 1 == 1, let touch = touches.first, let point = mapped(touch.location(in: self)) else { return }
        if phase == "move" {
            // About 60 a second: more only queues on the Mac.
            guard Date().timeIntervalSince(lastMove) > 1.0 / 60 else { return }
            lastMove = Date()
        }
        client?.send(["type": "touch", "phase": phase, "x": point.x, "y": point.y])
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touch("down", touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touch("move", touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touch("up", touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touch("up", touches, event) }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        let at = gesture.location(in: self)
        defer { lastScroll = gesture.state == .changed || gesture.state == .began ? at : nil }
        guard gesture.state == .changed, let last = lastScroll, let point = mapped(at), let header else { return }
        let scale = min(bounds.width / header.width, bounds.height / header.height)
        client?.send(["type": "scroll", "x": point.x, "y": point.y, "dx": (at.x - last.x) / scale, "dy": (at.y - last.y) / scale])
    }
}
