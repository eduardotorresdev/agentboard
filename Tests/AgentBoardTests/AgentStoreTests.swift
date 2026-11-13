import AgentRuntime
import AppKit
import Darwin
import ImageIO
import Connections
import Foundation
@testable import Orchestration
import Testing
@testable import AgentBoard

/// A core in this process, on `path`: the first one, or one taking over from the one there.
@MainActor
private func core(at path: String, folder: URL, inheriting inheritance: Inheritance? = nil) throws -> (CoreServer, Orchestrator) {
    let server = CoreServer(socketPath: path, queue: .main)
    server.lock = inheritance?.lock ?? open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    if let inheritance { server.adopt(inheritance.sessions) }
    let orchestrator = Orchestrator(server: server, dataFolder: folder, providers: [], searchPath: "/usr/bin:/bin",
                                    inheriting: inheritance?.service, descriptors: inheritance?.serviceDescriptors ?? [])
    server.service = orchestrator
    try server.start(listening: inheritance?.listener)
    return (server, orchestrator)
}

private func waitUntil(_ seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// Scenario 5 of GOAL.md, with the board's own store: the core is replaced while the board
/// runs, and the board reconnects by itself. No card shows as failed meanwhile, and the card's
/// program and screen carry on.
@MainActor
@Test func theBoardCarriesOnWhenTheCoreIsReplaced() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abstore-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    defer {
        unlink(path)
        unlink(path + ".lock")
    }
    // Held: a server's service is weak.
    let (old, oldOrchestrator) = try core(at: path, folder: folder)
    var handedOff = false
    old.onHandedOff = { handedOff = true }

    let store = AgentStore(connect: { CoreClient.open(socketPath: path, timeout: 2) })
    try await waitUntil { store.isLoaded }
    let record = store.addRunner(command: "i=0; while true; do i=$((i+1)); echo tick $i; sleep 0.05; done", name: "counter",
                                 directory: folder.path, to: folder.path, at: .zero)
    let session = store.session(for: record, cols: 80, rows: 24)
    func ticks() -> [Int] {
        session.withTerminal { $0.recentText(lines: 2000) }.compactMap { $0.hasPrefix("tick ") ? Int($0.dropFirst(5)) : nil }
    }
    try await waitUntil(60) { (ticks().last ?? 0) >= 10 }
    let pid = try #require(session.processID, "\(session.state)")
    let firstClient = try #require(store.core)

    // Watched throughout: a card that shows as failed even for a moment fails the test.
    var states: [AgentSession.State] = []
    let watching = Task { @MainActor in
        while !Task.isCancelled {
            if states.last != session.state { states.append(session.state) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    let inheritance = try #require(await Task.detached { CoreHandoff.takeOver(socketPath: path) }.value)
    let (new, newOrchestrator) = try core(at: path, folder: folder, inheriting: inheritance)
    defer {
        new.closeSession(record.id, grace: 0.5)
        new.stop()
        _ = (oldOrchestrator, newOrchestrator)
    }
    #expect(handedOff)
    try await waitUntil { store.core !== firstClient && store.core?.mirrors(session, id: record.id) == true }
    let after = ticks().last ?? 0
    try await waitUntil { (ticks().last ?? 0) >= after + 20 }
    watching.cancel()

    #expect(store.core !== firstClient)
    #expect(store.notice == nil)
    #expect(states == [.running], "states seen: \(states)")
    #expect(session.processID == pid)
    #expect((ticks().last ?? 0) >= after + 20)
    #expect(store.agents.map(\.id) == [record.id])
    // The mirror's screen is whole: every number once, in order.
    let seen = ticks()
    #expect(seen == Array((seen.first ?? 1)..<((seen.first ?? 1) + seen.count)), "\(seen)")
}

// MARK: Images

private func picture(_ width: Int, _ height: Int, as type: CFString = "public.png" as CFString) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func tempFolder() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abimg-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Case 16: adding stores the file, mirrors the record and tells the core, which tells other boards.
@MainActor
@Test func theBoardAddsImages() async throws {
    let folder = try tempFolder()
    let path = NSTemporaryDirectory() + "abcore-\(UUID().uuidString.prefix(8)).sock"
    defer {
        unlink(path)
        unlink(path + ".lock")
    }
    let (server, orchestrator) = try core(at: path, folder: folder)
    defer { server.stop() }
    let store = AgentStore(connect: { CoreClient.open(socketPath: path, timeout: 2) })
    store.dataFolder = folder
    let other = AgentStore(connect: { CoreClient.open(socketPath: path, timeout: 2) })
    try await waitUntil { store.isLoaded && other.isLoaded }

    let record = try store.addImage(.data(picture(800, 400)), named: "Image", to: folder.path, at: CGPoint(x: 10, y: 20))
    #expect(store.images == [record])
    #expect(record.frame == CGRect(origin: CGPoint(x: 10, y: 20), size: ImageRecord.cardSize(for: CGSize(width: 800, height: 400))))
    #expect(FileManager.default.fileExists(atPath: ImageFiles.url(of: record.file, in: folder).path))
    try await waitUntil { orchestrator.image(record.id) != nil && other.image(record.id) != nil }
    #expect(orchestrator.image(record.id) == record)
    #expect(other.image(record.id) == record)
    #expect(throws: ImageFiles.Failure.notAnImage) { try store.addImage(.data(Data("text".utf8)), named: "x", to: folder.path, at: .zero) }
    #expect(store.images.count == 1)
}

/// Case 16: the core's events add, update and remove; a removed image takes its lines along.
@MainActor
@Test func imageEventsReachTheBoard() throws {
    let store = AgentStore(connect: { .failure(.noCore) })
    let id = UUID(), agent = UUID()
    let record = ImageRecord(id: id, worktree: "/w", name: "Shot", frame: CGRect(x: 0, y: 0, width: 200, height: 132), file: "a.png",
                             pixelSize: CGSize(width: 200, height: 100))
    store.received(.imageAdded(record))
    #expect(store.images == [record])
    store.received(.connections([Connection(a: agent, b: id)]))
    var replaced = record
    replaced.file = "b.png"
    replaced.name = "Renamed"
    store.received(.imageUpdated(replaced))
    #expect(store.image(id) == replaced)
    #expect(store.connections(in: "/w", elements: [agent]).count == 1)
    store.received(.imageRemoved(id))
    #expect(store.images.isEmpty)
    #expect(store.connections.isEmpty)

    // Only this worktree and organization.
    let elsewhere = ImageRecord(id: UUID(), worktree: "/other", name: "A", frame: .zero, file: "c.png", pixelSize: CGSize(width: 1, height: 1))
    let otherOrganization = ImageRecord(id: UUID(), worktree: "/w", name: "B", frame: .zero, file: "d.png", pixelSize: CGSize(width: 1, height: 1),
                                        organization: UUID())
    let here = ImageRecord(id: UUID(), worktree: "/w", name: "C", frame: .zero, file: "e.png", pixelSize: CGSize(width: 1, height: 1))
    for image in [elsewhere, otherOrganization, here] { store.received(.imageAdded(image)) }
    #expect(store.images(in: "/w").map(\.id) == [here.id])
}

/// Case 17: what a paste finds on the pasteboard.
@MainActor
@Test func picturesOnThePasteboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("abtest-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let png = picture(20, 10)
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    #expect(ImageSource.read(from: pasteboard) == .data(png))

    let tiff = picture(20, 10, as: "public.tiff" as CFString)
    pasteboard.clearContents()
    pasteboard.setData(tiff, forType: .tiff)
    #expect(ImageSource.read(from: pasteboard) == .data(tiff))

    let folder = try tempFolder()
    let file = folder.appendingPathComponent("shot.png")
    try png.write(to: file)
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    #expect(ImageSource.read(from: pasteboard) == .file(file))

    pasteboard.clearContents()
    pasteboard.setString("hello", forType: .string)
    #expect(ImageSource.read(from: pasteboard) == nil)

    let text = folder.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: text)
    pasteboard.clearContents()
    // Finder puts the file's icon next to it: still not a picture.
    pasteboard.writeObjects([text as NSURL])
    pasteboard.addTypes([.tiff], owner: nil)
    pasteboard.setData(tiff, forType: .tiff)
    #expect(ImageSource.read(from: pasteboard) == nil)
}

/// Case 18: resizing from any edge or corner keeps the picture's proportion and the opposite side.
@Test func resizingKeepsTheProportion() {
    let pixels = CGSize(width: 1600, height: 900)
    let start = CGRect(origin: CGPoint(x: 100, y: 100), size: ImageRecord.cardSize(for: pixels))
    let all: [ImageResize.Edges] = [.left, .right, .top, .bottom, [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]]
    for edges in all {
        for delta in [CGSize(width: 60, height: 40), CGSize(width: -70, height: -50), CGSize(width: -900, height: -900)] {
            let frame = ImageResize.frame(resizing: start, edges: edges, by: delta, pixelSize: pixels)
            let picture = CGSize(width: frame.width, height: frame.height - ImageRecord.titleHeight)
            #expect(abs(picture.height - picture.width * 900 / 1600) <= 0.5, "\(edges) \(delta) \(frame)")
            #expect(frame.width >= ImageRecord.minimumWidth)
            #expect(edges.contains(.left) ? frame.maxX == start.maxX : frame.minX == start.minX, "\(edges) \(delta)")
            #expect(edges.contains(.top) ? frame.maxY == start.maxY : frame.minY == start.minY, "\(edges) \(delta)")
        }
    }
    // Growing from an edge grows the card; shrinking past the minimum stops there.
    #expect(ImageResize.frame(resizing: start, edges: .right, by: CGSize(width: 60, height: 0), pixelSize: pixels).width == start.width + 60)
    #expect(ImageResize.frame(resizing: start, edges: .bottom, by: CGSize(width: 0, height: 90), pixelSize: pixels).width == start.width + 160)
    #expect(ImageResize.frame(resizing: start, edges: .left, by: CGSize(width: 900, height: 0), pixelSize: pixels).width == ImageRecord.minimumWidth)
    #expect(ImageResize.edges(at: CGPoint(x: 101, y: 101), in: start, reach: 8) == [.left, .top])
    #expect(ImageResize.edges(at: CGPoint(x: start.midX, y: start.midY), in: start, reach: 8) == [])
}

/// Cmd+C copies the stored picture at its full size, not the card's display copy.
@MainActor
@Test func copyingGivesTheWholePicture() throws {
    let folder = try tempFolder()
    let stored = try ImageFiles.store(picture(3000, 1000), in: folder)
    let record = ImageRecord(id: UUID(), worktree: "/w", name: "Shot", frame: .zero, file: stored.file, pixelSize: stored.pixelSize)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("abtest-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    #expect(ImageSource.copy(record, in: folder, to: pasteboard))
    let rep = try #require(pasteboard.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:)))
    #expect(rep.pixelsWide == 3000 && rep.pixelsHigh == 1000)
}

/// The picture cache holds only pictures of cards that still show them.
@MainActor
@Test func thePictureCacheEmpties() async throws {
    let folder = try tempFolder()
    let first = try ImageFiles.store(picture(40, 20), in: folder), second = try ImageFiles.store(picture(20, 40), in: folder)
    var record = ImageRecord(id: UUID(), worktree: "/w", name: "Shot", frame: CGRect(x: 0, y: 0, width: 160, height: 112),
                             file: first.file, pixelSize: first.pixelSize)
    let card = ImageCardLayer()
    func show() { card.update(frame: record.frame, record: record, dataFolder: folder, focused: false, closeHovered: false, renaming: false, scale: 2) }
    show()
    try await waitUntil { ImageCardLayer.cache[first.file] != nil }
    record.file = second.file
    show()
    #expect(ImageCardLayer.cache[first.file] == nil)
    try await waitUntil { ImageCardLayer.cache[second.file] != nil }
    #expect(ImageCardLayer.cache[second.file] != nil)
    card.forget()
    #expect(ImageCardLayer.cache[second.file] == nil)
}
