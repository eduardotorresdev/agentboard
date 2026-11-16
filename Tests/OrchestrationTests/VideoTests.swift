import AVFoundation
import Connections
import CoreGraphics
import Foundation
import SQLite3
import Testing
@testable import Orchestration

/// A `seconds`-long H.264 clip, `width`×`height`, at `url`.
func makeVideo(at url: URL, width: Int = 64, height: Int = 48, seconds: Int = 1) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let fps = 10
    for frame in 0..<(seconds * fps) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

private func folder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abvideo-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `call`, counting the images in the result.
private func callCounting(_ tool: String, _ arguments: [String: Any], as caller: UUID, on core: Core) async throws -> (text: String, isError: Bool, images: Int) {
    let (url, token) = await MainActor.run { (core.orchestrator.toolsEndpoint, core.orchestrator.toolToken(for: caller)) }
    var request = URLRequest(url: try #require(url))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(answer["result"] as? [String: Any])
    let content = result["content"] as? [[String: Any]] ?? []
    return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), result["isError"] as? Bool ?? false,
            content.filter { $0["type"] as? String == "image" }.count)
}

@Suite(.serialized)
struct VideoTests {
    @Test func videosAreValidatedAndStored() async throws {
        let dir = try folder()
        let clip = dir.appendingPathComponent("clip.mp4")
        try await makeVideo(at: clip, width: 64, height: 48, seconds: 2)
        #expect(ImageFiles.isVideoFile(clip))

        let stored = try ImageFiles.store(contentsOf: clip, in: dir)
        #expect(stored.pixelSize == CGSize(width: 64, height: 48))
        #expect(abs((stored.duration ?? 0) - 2) < 0.2)
        #expect(stored.file.hasSuffix(".mp4"))

        // A container AVFoundation doesn't open natively, and bytes that aren't a video.
        let avi = dir.appendingPathComponent("clip.avi")
        try FileManager.default.copyItem(at: clip, to: avi)
        #expect(throws: ImageFiles.Failure.notPlayable) { try ImageFiles.store(contentsOf: avi, in: dir) }
        let fake = dir.appendingPathComponent("fake.mov")
        try Data("not a video".utf8).write(to: fake)
        #expect(throws: ImageFiles.Failure.notPlayable) { try ImageFiles.store(contentsOf: fake, in: dir) }

        // Larger than the video limit (sparse, so nothing is really written).
        let large = dir.appendingPathComponent("large.mp4")
        try FileManager.default.copyItem(at: clip, to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ImageFiles.maximumVideoBytes + 1))
        try handle.close()
        #expect(throws: ImageFiles.Failure.tooLarge) { try ImageFiles.store(contentsOf: large, in: dir) }

        let frames = try #require(ImageFiles.readingVideo(stored.file, in: dir))
        #expect(frames.count == ImageFiles.readFrames)
        #expect(frames.map(\.second) == frames.map(\.second).sorted())
    }

    /// An images table from before videos (no duration column) keeps its pictures.
    @Test func oldImagesSurviveTheMigration() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("agentboard.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let id = UUID()
        let sql = """
            CREATE TABLE images (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, name TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL, file TEXT NOT NULL,
                pixel_width REAL NOT NULL, pixel_height REAL NOT NULL, organization TEXT);
            INSERT INTO images VALUES ('\(id.uuidString)', '/w', 'Shot', 1, 2, 300, 232, 'a.png', 600, 400, NULL);
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let database = try CardDatabase(url: url)
        let images = try database.images()
        #expect(images == [ImageRecord(id: id, worktree: "/w", name: "Shot", frame: CGRect(x: 1, y: 2, width: 300, height: 232),
                                       file: "a.png", pixelSize: CGSize(width: 600, height: 400))])
        #expect(images.first?.isVideo == false)

        let video = ImageRecord(id: UUID(), worktree: "/w", name: "Clip", frame: .zero, file: "b.mp4",
                                pixelSize: CGSize(width: 64, height: 48), duration: 2.5)
        try database.saveImage(video)
        #expect(try CardDatabase(url: url).images().map(\.duration) == [nil, 2.5])
    }

    /// A board or core from before videos sends records without `duration`: they decode as pictures.
    @Test func recordsWithoutDurationDecodeAsPictures() throws {
        let record = ImageRecord(id: UUID(), worktree: "/w", name: "Shot", frame: .zero, file: "a.png", pixelSize: CGSize(width: 2, height: 2))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["duration"] = nil
        let decoded = try JSONDecoder().decode(ImageRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == record && !decoded.isVideo)
    }

    @Test func agentsChooseBetweenImageAndVideoTools() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        await MainActor.run { core.orchestrator.insert(a) }
        try await makeVideo(at: folder.appendingPathComponent("demo.mov"), width: 80, height: 60, seconds: 1)

        let wrong = try await callCounting("image_create", ["path": "demo.mov"], as: a.id, on: core)
        #expect(wrong.isError && wrong.text.contains("video_create"), "\(wrong.text)")
        let created = try await callCounting("video_create", ["path": "demo.mov", "name": "Demo"], as: a.id, on: core)
        #expect(!created.isError, "\(created.text)")
        let record = try #require(await core.orchestrator.images.first)
        #expect(record.isVideo && record.pixelSize == CGSize(width: 80, height: 60))
        #expect(await MainActor.run { core.orchestrator.bus.peers(of: a.id, kind: .video).map(\.id) } == [record.id])

        let peers = try await call("list_peers", as: a.id, on: core)
        #expect(peers.text.contains("Demo (video, 80×60"), "\(peers.text)")
        let noImage = try await callCounting("image_read", [:], as: a.id, on: core)
        #expect(noImage.isError && noImage.text.contains("No image"), "\(noImage.text)")

        let read = try await callCounting("video_read", ["video": "Demo"], as: a.id, on: core)
        #expect(!read.isError && read.images == ImageFiles.readFrames && read.text.contains("80×60"), "\(read.text)")

        let notVideo = folder.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: notVideo)
        let refused = try await callCounting("video_replace", ["path": "a.txt"], as: a.id, on: core)
        #expect(refused.isError && refused.text.contains("image_create"), "\(refused.text)")

        let removed = try await callCounting("video_remove", [:], as: a.id, on: core)
        #expect(!removed.isError, "\(removed.text)")
        #expect(await core.orchestrator.images.isEmpty)
    }
}
