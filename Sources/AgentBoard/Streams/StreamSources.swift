import Foundation

/// Simulator cards: the same devices the board and the agents drive.
extension SimulatorStore: StreamSource {
    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? {
        switch record(card)?.platform {
        case .ios: ios.stream(card, to: sink)
        case .android: android.stream(card, to: sink)
        case nil: nil
        }
    }

    func input(_ card: UUID, _ event: StreamWire.Input) {
        switch event {
        case .touch(let phase, let x, let y): touch(card, phase, at: CGPoint(x: x, y: y))
        case .scroll(let x, let y, let dx, let dy): scroll(card, at: CGPoint(x: x, y: y), by: CGSize(width: dx, height: dy))
        case .key(let usage?, _, let down, let characters): key(card, usage: usage, down: down, characters: characters)
        case .key(nil, let name?, true, _): Task { try? await press(card, name) }
        case .key: break
        case .text(let text): type(card, text)
        case .button(let name): button(card, name)
        }
    }

    func requestKeyFrame(_ card: UUID) {
        switch record(card)?.platform {
        case .ios: ios.requestKeyFrame(card)
        case .android: android.requestKeyFrame(card)
        case nil: break
        }
    }
}

/// Browser cards: the page's screencast, input as the card's own.
extension BrowserStore: StreamSource {
    func stream(_ card: UUID, to sink: @escaping StreamTaps.Sink) -> (() -> Void)? {
        guard pages[card] != nil else { return nil }
        let id = taps.add(card, sink)
        Task { _ = try? await call("screencast", on: card, ["on": true]) }
        return { [weak self] in
            guard let self, self.taps.remove(card, id), self.pages[card]?.phase == .open else { return }
            self.host.post("screencast", ["block": card.uuidString, "on": false])
        }
    }

    func input(_ card: UUID, _ event: StreamWire.Input) {
        switch event {
        case .touch(let phase, let x, let y): input(card, ["kind": phase, "x": x, "y": y])
        // The stream's deltas are how far the content moves; a wheel's, how far the page scrolls.
        case .scroll(let x, let y, let dx, let dy): input(card, ["kind": "wheel", "x": x, "y": y, "dx": -dx, "dy": -dy])
        case .key(_, let name?, true, _): input(card, ["kind": "key", "key": name])
        case .key: break
        case .text(let text): input(card, ["kind": "text", "text": text])
        case .button: break
        }
    }

    /// Every JPEG stands alone.
    func requestKeyFrame(_ card: UUID) {}

    /// A watched page that failed (its sidecar stopped, the page crashed) opens again by itself,
    /// whether or not the Mac board shows the card; `resumeStream` then restarts its stream. A
    /// sidecar that keeps failing is tried every 2 s while someone watches.
    func recoverStream(_ card: UUID) {
        guard taps.watched(card), case .failed = pages[card]?.phase else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard taps.watched(card) else { return }
            reopen(card)
        }
    }

    /// The card's page opened again (its sidecar restarted, its profile changed): a stream
    /// watching it starts over on the new page, header first.
    func resumeStream(_ card: UUID) {
        guard taps.watched(card) else { return }
        taps.reset(card)
        host.post("screencast", ["block": card.uuidString, "on": true])
    }
}
