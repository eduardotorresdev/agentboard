import AgentRuntime
import Connections
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Orchestration

/// A picture `width`×`height` encoded as `type`.
func picture(_ width: Int, _ height: Int, as type: UTType = .png) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func write(_ data: Data, _ name: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func storedFiles(_ core: Core) async -> [String] {
    let folder = await MainActor.run { ImageFiles.folder(in: core.folder) }
    return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
}

/// `call`, with the image content too.
private func read(_ arguments: [String: Any] = [:], as caller: UUID, on core: Core) async throws -> (text: String, isError: Bool, image: Data?, mimeType: String?) {
    let (url, token) = await MainActor.run { (core.orchestrator.toolsEndpoint, core.orchestrator.toolToken(for: caller)) }
    var request = URLRequest(url: try #require(url))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "image_read", "arguments": arguments],
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(answer["result"] as? [String: Any])
    let content = result["content"] as? [[String: Any]] ?? []
    let image = content.first { $0["type"] as? String == "image" }
    return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), result["isError"] as? Bool ?? false,
            (image?["data"] as? String).flatMap { Data(base64Encoded: $0) }, image?["mimeType"] as? String)
}

private func pixelSize(of data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: width, height: height)
}

/// An image record whose file a board stored.
private func boardImage(_ name: String, _ data: Data, in folder: URL) throws -> ImageRecord {
    let stored = try ImageFiles.store(data, in: folder)
    return ImageRecord(id: UUID(), worktree: folder.path, name: name, frame: CGRect(origin: .zero, size: ImageRecord.cardSize(for: stored.pixelSize)),
                       file: stored.file, pixelSize: stored.pixelSize)
}

@Suite(.serialized)
struct ImageTests {
    /// Case 1, 2, 14: `image_create` copies the file in, connects the card, and other boards hear of it.
    @Test func agentsCreateImages() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let client = try await board(core)
        let inbox = Inbox()
        client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        client.send(.addCard(a))
        try await waitUntil { core.orchestrator.record(a.id) != nil }
        let png = picture(800, 400)
        let source = try write(png, "shot.png", in: folder)

        let created = try await call("image_create", ["path": "shot.png"], as: a.id, on: core)
        #expect(!created.isError, "\(created.text)")
        let record = try #require(await core.orchestrator.images.first)
        #expect(record.name == "Image")
        #expect(record.pixelSize == CGSize(width: 800, height: 400))
        #expect(record.frame.size == ImageRecord.cardSize(for: record.pixelSize))
        #expect(record.frame.minX > a.frame.maxX)
        #expect(try Data(contentsOf: ImageFiles.url(of: record.file, in: folder)) == png)
        #expect(try Data(contentsOf: source) == png)
        #expect(await MainActor.run { core.orchestrator.bus.peers(of: a.id, kind: .image).map(\.id) } == [record.id])
        try await waitUntil { inbox.events.contains { if case .imageAdded(let added) = $0 { added.id == record.id } else { false } } }
        #expect(inbox.events.contains { if case .imageAdded(let added) = $0 { added.id == record.id } else { false } })

        let peers = try await call("list_peers", as: a.id, on: core)
        #expect(peers.text.contains("“Image” (image, id: \(record.id.uuidString), made by: you, connected: true, 800×400"), "\(peers.text)")

        // `~` resolves to the home folder; checked with a file that isn't there, so nothing is written to HOME.
        let name = ".abtest-\(UUID().uuidString.prefix(8)).png"
        let fromHome = try await call("image_create", ["path": "~/" + name, "name": "Chart"], as: a.id, on: core)
        let expanded = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name).path
        #expect(fromHome.isError && fromHome.text.contains(expanded), "\(fromHome.text)")
        #expect(await core.orchestrator.images.map(\.name) == ["Image"])
        client.disconnect()
    }

    /// Case 3: missing, not an image, too large: tool errors, nothing kept.
    @Test func refusedFilesLeaveNothing() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        await MainActor.run { core.orchestrator.insert(a) }
        _ = try write(Data("not a picture".utf8), "fake.png", in: folder)
        let large = folder.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: large.path, contents: picture(10, 10))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ImageFiles.maximumBytes + 1))
        try handle.close()

        let missing = try await call("image_create", ["path": "nowhere.png"], as: a.id, on: core)
        #expect(missing.isError && missing.text.contains("no file"), "\(missing.text)")
        let fake = try await call("image_create", ["path": "fake.png"], as: a.id, on: core)
        #expect(fake.isError && fake.text.contains("isn't an image"), "\(fake.text)")
        let tooLarge = try await call("image_create", ["path": large.path], as: a.id, on: core)
        #expect(tooLarge.isError && tooLarge.text.contains("20 MB"), "\(tooLarge.text)")
        #expect(await core.orchestrator.images.isEmpty)
        #expect(await storedFiles(core).isEmpty)
    }

    /// Case 4: default names count up, case-insensitively; a given name is kept.
    @Test func namesAreUnique() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        await MainActor.run { core.orchestrator.insert(a) }
        _ = try write(picture(20, 20), "a.png", in: folder)
        for arguments in [["path": "a.png"], ["path": "a.png"], ["path": "a.png", "name": "Plot"], ["path": "a.png", "name": "plot"]] {
            let result = try await call("image_create", arguments, as: a.id, on: core)
            #expect(!result.isError, "\(result.text)")
        }
        #expect(await core.orchestrator.images.map(\.name) == ["Image", "Image 2", "Plot", "plot 2"])
        #expect(ImageRecord.uniqueName("image", among: await core.orchestrator.images) == "image 3")
    }

    /// Case 5, 6: what `image_read` gives, and when it refuses.
    @Test func agentsReadImages() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        await MainActor.run { core.orchestrator.insert(a) }

        let none = try await read(as: a.id, on: core)
        #expect(none.isError && none.text.contains("No image is connected"), "\(none.text)")

        let small = try boardImage("Small", picture(200, 100), in: folder)
        let big = try boardImage("Big", picture(5000, 3000, as: .jpeg), in: folder)
        let tiff = try boardImage("Scan", picture(300, 200, as: .tiff), in: folder)
        let heic = try boardImage("Photo", picture(300, 200, as: .heic), in: folder)
        let loose = try boardImage("Loose", picture(10, 10), in: folder)
        await MainActor.run {
            for record in [small, big, tiff, heic, loose] { core.orchestrator.insertImage(record) }
            core.orchestrator.bus.connect(a.id, small.id)
        }

        let only = try await read(as: a.id, on: core)
        #expect(!only.isError, "\(only.text)")
        #expect(only.mimeType == "image/png")
        #expect(only.image.flatMap(pixelSize) == CGSize(width: 200, height: 100))
        #expect(only.text.contains("200×100"))
        // The user's marks: the marked copy by its file name, never a path out of the pictures folder.
        let marked = try await read(["marks": loose.file], as: a.id, on: core)
        #expect(!marked.isError && marked.text.contains("Small with the user's marks drawn on it") && marked.text.contains("200×100"), "\(marked.text)")
        #expect(marked.image.flatMap(pixelSize) == CGSize(width: 10, height: 10))
        let outside = try await read(["marks": "../agentboard.sqlite"], as: a.id, on: core)
        #expect(outside.isError && outside.text.contains("There are no marks"), "\(outside.text)")

        await MainActor.run { for id in [big.id, tiff.id, heic.id] { core.orchestrator.bus.connect(a.id, id) } }
        let several = try await read(as: a.id, on: core)
        #expect(several.isError && several.text.contains("Several images"), "\(several.text)")
        let unconnected = try await read(["image": "Loose"], as: a.id, on: core)
        #expect(unconnected.isError && unconnected.text.contains("No image named “Loose”"), "\(unconnected.text)")
        let unknown = try await read(["image": "Nope"], as: a.id, on: core)
        #expect(unknown.isError)

        let scaled = try await read(["image": "BIG"], as: a.id, on: core)
        #expect(scaled.mimeType == "image/jpeg")
        let side = try #require(scaled.image.flatMap(pixelSize))
        #expect(max(side.width, side.height) == CGFloat(ImageFiles.readSide))
        #expect(abs(side.width / side.height - 5000.0 / 3000.0) < 0.01)
        for name in ["Scan", "Photo"] {
            let converted = try await read(["image": name], as: a.id, on: core)
            #expect(converted.mimeType == "image/png", "\(name)")
            #expect(converted.image.flatMap(pixelSize) == CGSize(width: 300, height: 200), "\(name)")
        }
    }

    /// Case 7, 8: replacing and removing, on an image a board added.
    @Test func agentsReplaceAndRemoveImages() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let client = try await board(core)
        let inbox = Inbox()
        client.onService { data in if let event = BoardEvent(data) { inbox.add(event) } }
        let other = try await board(core)
        let otherInbox = Inbox()
        other.onService { data in if let event = BoardEvent(data) { otherInbox.add(event) } }
        let image = try boardImage("Shot", picture(400, 200), in: folder)
        client.send(.addCard(a))
        client.send(.addImage(image))
        client.send(.connect(Connection(a: a.id, b: image.id)))
        try await waitUntil { core.orchestrator.bus.graph.connections.count == 1 }
        _ = try write(picture(300, 300), "square.png", in: folder)

        let bad = try await call("image_replace", ["path": "nowhere.png"], as: a.id, on: core)
        #expect(bad.isError)
        #expect(await core.orchestrator.image(image.id) == image)

        let replaced = try await call("image_replace", ["path": "square.png"], as: a.id, on: core)
        #expect(!replaced.isError, "\(replaced.text)")
        let now = try #require(await core.orchestrator.image(image.id))
        #expect(now.file != image.file)
        #expect(now.name == "Shot")
        #expect(now.pixelSize == CGSize(width: 300, height: 300))
        #expect(now.frame.width == image.frame.width)
        #expect(now.frame.height == image.frame.width + ImageRecord.titleHeight)
        #expect(!FileManager.default.fileExists(atPath: ImageFiles.url(of: image.file, in: folder).path))
        try await waitUntil { otherInbox.events.contains { if case .imageUpdated(let r) = $0 { r.file == now.file } else { false } } }
        #expect(otherInbox.events.contains { if case .imageUpdated(let r) = $0 { r.file == now.file } else { false } })

        // The user's image: a board is asked first (whichever the core picks), and allows it here.
        for (board, events) in [(client, inbox), (other, otherInbox)] {
            board.send(.elements([]))  // boards that run board tools say which elements they have
            board.onService { data in
                guard let event = BoardEvent(data) else { return }
                events.add(event)
                if case .toolCall(let call, "board_confirm_removal", _, _) = event { board.send(.toolResult(call: call, result: WireToolResult(.text("allowed")))) }
            }
        }
        let removed = try await call("image_remove", as: a.id, on: core)
        #expect(!removed.isError, "\(removed.text)")
        #expect(await core.orchestrator.images.isEmpty)
        #expect(await core.orchestrator.bus.graph.connections.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ImageFiles.url(of: now.file, in: folder).path))
        try await waitUntil { inbox.events.contains { if case .imageRemoved(image.id) = $0 { true } else { false } } }
        #expect(inbox.events.contains { if case .imageRemoved(image.id) = $0 { true } else { false } })
        client.disconnect()
        other.disconnect()
    }

    /// Case 9: one line of context per change, never for what the agent did itself.
    @Test func imagesReachContext() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        let shot = try boardImage("Shot", picture(40, 20), in: folder)
        let chart = try boardImage("Chart", picture(40, 20), in: folder)
        await MainActor.run {
            core.orchestrator.insert(a)
            core.orchestrator.insert(b)
            core.orchestrator.insertImage(shot)
            core.orchestrator.insertImage(chart)
            core.orchestrator.bus.connect(a.id, shot.id)
            core.orchestrator.bus.connect(b.id, shot.id)
        }
        _ = try write(picture(60, 20), "new.png", in: folder)

        let start = try await context("SessionStart", as: a.id, on: core)
        #expect(start?.contains("“Shot” (40×20) is connected") == true, "\(start ?? "nil")")
        #expect(try await context("UserPromptSubmit", as: a.id, on: core) == nil)

        await MainActor.run { _ = core.orchestrator.bus.connect(a.id, chart.id) }
        let connected = try await context("UserPromptSubmit", as: a.id, on: core)
        #expect(connected?.contains("“Chart”") == true, "\(connected ?? "nil")")
        #expect(connected?.contains("Shot") == false)
        #expect(try await context("UserPromptSubmit", as: a.id, on: core) == nil)

        _ = try await call("image_replace", ["path": "new.png", "image": "Shot"], as: b.id, on: core)
        let replaced = try await context("PostToolUse", as: a.id, on: core)
        #expect(replaced?.contains("“Shot” has a new picture (60×20)") == true, "\(replaced ?? "nil")")
        // A rename is a rename, not a new picture.
        await MainActor.run { core.orchestrator.updateImage(shot.id) { $0.name = "Login" } }
        let renamed = try await context("UserPromptSubmit", as: a.id, on: core)
        #expect(renamed?.contains("“Shot” is now called “Login”") == true, "\(renamed ?? "nil")")
        #expect(renamed?.contains("new picture") == false)
        await MainActor.run { core.orchestrator.updateImage(shot.id) { $0.name = "Shot" } }
        _ = try await context("UserPromptSubmit", as: a.id, on: core)
        _ = try await context("SessionStart", as: b.id, on: core)
        _ = try await call("image_replace", ["path": "new.png", "image": "Shot"], as: b.id, on: core)
        #expect(try await context("PostToolUse", as: b.id, on: core) == nil)
        _ = try await call("image_create", ["path": "new.png"], as: b.id, on: core)
        #expect(try await context("PostToolUse", as: b.id, on: core) == nil)

        await MainActor.run { core.orchestrator.removeImage(chart.id) }
        let removed = try await context("UserPromptSubmit", as: a.id, on: core)
        #expect(removed?.contains("“Chart” is no longer connected") == true, "\(removed ?? "nil")")
    }

    /// Case 10, 11, 12: the board's requests, and what outlives the core.
    @Test func boardRequestsAndRelaunch() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        let sender = try await board(core)
        let senderInbox = Inbox()
        sender.onService { data in if let event = BoardEvent(data) { senderInbox.add(event) } }
        let other = try await board(core)
        let otherInbox = Inbox()
        other.onService { data in if let event = BoardEvent(data) { otherInbox.add(event) } }
        let image = try boardImage("Shot", picture(100, 50), in: folder)
        var missing = try boardImage("Gone", picture(10, 10), in: folder)
        ImageFiles.remove(missing.file, in: folder)
        missing.name = "Gone"

        sender.send(.addCard(a))
        sender.send(.addImage(image))
        sender.send(.addImage(missing))
        // A file name that points out of the images folder is refused.
        var escaping = try boardImage("Escape", picture(10, 10), in: folder)
        escaping.file = "../agentboard.sqlite"
        sender.send(.addImage(escaping))
        var duplicate = image
        duplicate.name = "Copy"
        sender.send(.addImage(duplicate))
        sender.send(.connect(Connection(a: a.id, b: image.id)))
        try await waitUntil { core.orchestrator.bus.graph.connections.count == 1 }
        #expect(await core.orchestrator.images.map(\.name) == ["Shot"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("agentboard.sqlite").path))
        try await waitUntil { otherInbox.events.contains { if case .imageAdded = $0 { true } else { false } } }
        #expect(!senderInbox.events.contains { if case .imageAdded = $0 { true } else { false } })

        var moved = image
        moved.name = "Renamed"
        moved.frame.origin = CGPoint(x: 50, y: 60)
        moved.file = "elsewhere.png"
        moved.pixelSize = CGSize(width: 1, height: 1)
        sender.send(.updateImage(moved))
        try await waitUntil { core.orchestrator.image(image.id)?.name == "Renamed" }
        let updated = try #require(await core.orchestrator.image(image.id))
        #expect(updated.frame.origin == CGPoint(x: 50, y: 60))
        #expect(updated.file == image.file)
        #expect(updated.pixelSize == image.pixelSize)

        // The welcome carries the images; an older core's has none.
        let late = try await board(core)
        let state = try #require(BoardState(late.serviceState ?? Data()))
        #expect(state.images?.map(\.id) == [image.id])
        late.disconnect()
        var json = try #require(try JSONSerialization.jsonObject(with: state.encoded) as? [String: Any])
        json["images"] = nil
        #expect(try #require(BoardState(try JSONSerialization.data(withJSONObject: json))).images == nil)

        // Removing deletes the file.
        let extra = try boardImage("Extra", picture(10, 10), in: folder)
        sender.send(.addImage(extra))
        try await waitUntil { core.orchestrator.image(extra.id) != nil }
        sender.send(.removeImage(extra.id))
        try await waitUntil { core.orchestrator.image(extra.id) == nil }
        #expect(!FileManager.default.fileExists(atPath: ImageFiles.url(of: extra.file, in: folder).path))

        sender.disconnect()
        other.disconnect()
        await MainActor.run { core.stop() }
        let (images, connections) = await MainActor.run { () -> ([ImageRecord], [Connection]) in
            let server = CoreServer(socketPath: NSTemporaryDirectory() + "abcore-unused.sock", queue: .main)
            let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [EchoAgent()], searchPath: "/usr/bin:/bin")
            return (orchestrator.images, orchestrator.bus.graph.connections)
        }
        #expect(images == [updated])
        #expect(connections.count == 1)

    }

    /// Case 13.
    @Test func cardSizes() {
        let title = ImageRecord.titleHeight
        #expect(ImageRecord.cardSize(for: CGSize(width: 4000, height: 2000)) == CGSize(width: 480, height: 240 + title))
        #expect(ImageRecord.cardSize(for: CGSize(width: 100, height: 50)) == CGSize(width: 160, height: 80 + title))
        #expect(ImageRecord.cardSize(for: CGSize(width: 1000, height: 3000)) == CGSize(width: 160, height: 480 + title))
        #expect(ImageRecord.cardSize(width: 20, for: CGSize(width: 100, height: 100)) == CGSize(width: 160, height: 160 + title))
    }

    /// Case 15.
    @Test func storingFiles() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abtest-\(UUID().uuidString.prefix(8))")
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpeg"), (.gif, "gif")] {
            let source = try write(picture(30, 20, as: type), "x", in: try { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder }())
            let stored = try ImageFiles.store(contentsOf: source, in: folder)
            #expect(stored.pixelSize == CGSize(width: 30, height: 20))
            #expect(stored.file.hasSuffix("." + ext), "\(stored.file)")
            #expect(try Data(contentsOf: ImageFiles.url(of: stored.file, in: folder)) == Data(contentsOf: source))
        }
        // Through a symlink, the file it points at.
        let target = try write(picture(12, 8), "target.png", in: folder)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try ImageFiles.store(contentsOf: link, in: folder).pixelSize == CGSize(width: 12, height: 8))
        let pasted = try ImageFiles.store(picture(7, 9), in: folder)
        #expect(pasted.pixelSize == CGSize(width: 7, height: 9))
        #expect(throws: ImageFiles.Failure.notAnImage) { try ImageFiles.store(Data("hello".utf8), in: folder) }
        #expect(throws: ImageFiles.Failure.tooLarge) { try ImageFiles.store(Data(count: ImageFiles.maximumBytes + 1), in: folder) }
        #expect(throws: ImageFiles.Failure.missing) { try ImageFiles.store(contentsOf: folder.appendingPathComponent("none"), in: folder) }
    }
}
