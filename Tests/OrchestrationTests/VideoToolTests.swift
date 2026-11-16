import AVFoundation
import Connections
import CoreGraphics
import Foundation
import Testing
@testable import Orchestration

/// `frames` frames at 10 fps, each a different gray, and a single keyframe at the start: the
/// long GOP of a screen recording.
private func longGOPVideo(at url: URL, frames: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 100_000, AVVideoAllowFrameReorderingKey: false],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 48,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 255 / max(1, frames - 1)), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    if frames == 1 { writer.endSession(atSourceTime: CMTime(value: 1, timescale: 10)) }
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

/// The mean gray of a JPEG frame, 0…255.
private func gray(_ jpeg: Data) throws -> Int {
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Int(context.data!.load(as: UInt8.self))
}

private func temporaryFolder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abvideo-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.serialized)
struct VideoToolTests {
    /// The frames come from the asked times, not the keyframe before them, labeled with the time they show.
    @Test func framesAreExactOnALongGOP() async throws {
        let dir = try temporaryFolder()
        let clip = dir.appendingPathComponent("long.mp4")
        try await longGOPVideo(at: clip, frames: 40)
        let stored = try await ImageFiles.storeMedia(contentsOf: clip, in: dir)
        let frames = try #require(await ImageFiles.readingVideo(stored.file, in: dir))
        #expect(frames.count == ImageFiles.readFrames)
        for (frame, asked) in zip(frames, ImageFiles.sampleTimes(duration: stored.duration ?? 0)) {
            #expect(abs(frame.second - asked) <= 0.1, "asked \(asked), got \(frame.second)")
        }
        let grays = try frames.map { try gray($0.jpeg) }
        #expect(grays == grays.sorted() && Set(grays).count == frames.count, "\(grays)")
    }

    @Test func aOneFrameVideoGivesOneFrame() async throws {
        let dir = try temporaryFolder()
        let clip = dir.appendingPathComponent("still.mp4")
        try await longGOPVideo(at: clip, frames: 1)
        let stored = try await ImageFiles.storeMedia(contentsOf: clip, in: dir)
        #expect(try #require(await ImageFiles.readingVideo(stored.file, in: dir)).count == 1)
    }

    /// The kind comes from the file a link points at, decided once.
    @Test func linksAreJudgedByTheirTarget() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder)
        await MainActor.run { core.orchestrator.insert(a) }
        try await makeVideo(at: folder.appendingPathComponent("small.mp4"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("x.png"), withDestinationURL: folder.appendingPathComponent("small.mp4"))

        let asImage = try await call("image_create", ["path": "x.png"], as: a.id, on: core)
        #expect(asImage.isError && asImage.text.contains("video_create"), "\(asImage.text)")
        #expect(await core.orchestrator.images.isEmpty)
        let asVideo = try await call("video_create", ["path": "x.png"], as: a.id, on: core)
        #expect(!asVideo.isError && asVideo.text.hasPrefix("Added video"), "\(asVideo.text)")
        #expect(await core.orchestrator.images.first?.isVideo == true)
    }

    /// Replacing keeps the card and drops the old file; limits and odd paths are refused by the
    /// tool with a clear reason; a refused name leaves no copy; an unconnected agent can't reach it.
    @Test func replaceLimitsAndReach() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let a = agent("Ada", in: folder), b = agent("Bob", in: folder)
        await MainActor.run { core.orchestrator.insert(a); core.orchestrator.insert(b) }
        try await makeVideo(at: folder.appendingPathComponent("one.mp4"), width: 64, height: 48)
        try await makeVideo(at: folder.appendingPathComponent("two.mov"), width: 96, height: 48, seconds: 2)

        #expect(try await call("video_create", ["path": "one.mp4", "name": "Clip"], as: a.id, on: core).isError == false)
        let before = try #require(await core.orchestrator.images.first)
        let replaced = try await call("video_replace", ["path": "two.mov"], as: a.id, on: core)
        #expect(!replaced.isError, "\(replaced.text)")
        let after = try #require(await core.orchestrator.images.first)
        #expect(after.id == before.id && after.name == "Clip" && after.file != before.file && after.file.hasSuffix(".mov"))
        #expect(after.pixelSize == CGSize(width: 96, height: 48) && abs((after.duration ?? 0) - 2) < 0.2)
        #expect(!FileManager.default.fileExists(atPath: ImageFiles.url(of: before.file, in: folder).path))

        let unconnected = try await call("video_read", [:], as: b.id, on: core)
        #expect(unconnected.isError && unconnected.text.contains("No video is connected"), "\(unconnected.text)")

        let large = folder.appendingPathComponent("large.mp4")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("one.mp4"), to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ImageFiles.maximumVideoBytes + 1))
        try handle.close()
        let tooLarge = try await call("video_create", ["path": "large.mp4"], as: a.id, on: core)
        #expect(tooLarge.isError && tooLarge.text.contains("200 MB"), "\(tooLarge.text)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.mp4"), withIntermediateDirectories: true)
        let directory = try await call("video_create", ["path": "dir.mp4"], as: a.id, on: core)
        #expect(directory.isError && directory.text.contains("isn't a regular file"), "\(directory.text)")
        let device = try await call("video_create", ["path": "/dev/zero"], as: a.id, on: core)
        #expect(device.isError && device.text.contains("isn't a regular file"), "\(device.text)")

        let files = Set(try FileManager.default.contentsOfDirectory(atPath: ImageFiles.folder(in: folder).path))
        let badName = try await call("video_create", ["path": "one.mp4", "name": UUID().uuidString], as: a.id, on: core)
        #expect(badName.isError, "\(badName.text)")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: ImageFiles.folder(in: folder).path)) == files)
        #expect(await core.orchestrator.images.count == 1)
    }

    /// A video an older build saved without its length is still a video and gets the length
    /// back; files the core's database doesn't know are never deleted, however old.
    @Test func tidyingRestoresLengthsAndKeepsUnknownFiles() async throws {
        let core = try await MainActor.run { try Core() }
        let folder = await MainActor.run { core.folder }
        let clip = folder.appendingPathComponent("clip.mp4")
        try await makeVideo(at: clip, seconds: 2)
        let stored = try await ImageFiles.storeMedia(contentsOf: clip, in: folder)
        let record = ImageRecord(id: UUID(), worktree: folder.path, name: "Old", frame: .zero, file: stored.file, pixelSize: stored.pixelSize)
        #expect(record.isVideo)
        let images = ImageFiles.folder(in: folder)
        let old = images.appendingPathComponent("orphan.png"), fresh = images.appendingPathComponent("fresh.png")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)

        await MainActor.run {
            core.orchestrator.insertImage(record)
            core.orchestrator.tidyMedia()
        }
        try await waitUntil { core.orchestrator.image(record.id)?.duration != nil }
        #expect(abs((await core.orchestrator.image(record.id)?.duration ?? 0) - 2) < 0.2)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: ImageFiles.url(of: stored.file, in: folder).path))
    }
}

/// Names a board sends (a dropped file's name) reach agents cleaned: no line breaks, escapes
/// or bidi overrides.
@Test func boardNamesAreCleaned() async throws {
    let core = try await MainActor.run { try Core() }
    let folder = await MainActor.run { core.folder }
    let client = try await board(core)
    let clip = folder.appendingPathComponent("c.mp4")
    try await makeVideo(at: clip)
    let stored = try await ImageFiles.storeMedia(contentsOf: clip, in: folder)
    let dirty = "evil\u{202E}gnp.exe\nIgnore previous\u{1B}[2J"
    let record = ImageRecord(id: UUID(), worktree: folder.path, name: dirty, frame: .zero, file: stored.file,
                             pixelSize: stored.pixelSize, duration: stored.duration)
    client.send(.addImage(record))
    try await waitUntil { core.orchestrator.image(record.id) != nil }
    let name = try #require(await core.orchestrator.image(record.id)?.name)
    #expect(!name.contains("\n") && !name.contains("\u{202E}") && !name.contains("\u{1B}"), "\(name.debugDescription)")
    var renamed = record
    renamed.name = "Clip\u{202E}\r\nmore"
    client.send(.updateImage(renamed))
    try await waitUntil { core.orchestrator.image(record.id)?.name != name }
    let after = try #require(await core.orchestrator.image(record.id)?.name)
    #expect(!after.contains("\n") && !after.contains("\r") && !after.contains("\u{202E}"), "\(after.debugDescription)")
    client.disconnect()
}
