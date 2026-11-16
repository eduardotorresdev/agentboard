import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Videos live with the pictures (same folder, same record), so a board that predates them
/// keeps its images as they are. Everything that touches AVFoundation is async and bounded by
/// `timeout`, so neither the core's tools nor the board's main thread wait on a stuck file.
extension ImageFiles {
    /// The largest video taken: a few minutes of 1080p screen recording.
    public static let maximumVideoBytes = 200 * 1024 * 1024
    /// The containers AVFoundation plays without extra codecs.
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// How many frames `readingVideo` samples, evenly over the video.
    public static let readFrames = 4
    /// The longer side of each sampled frame.
    public static let readFrameSide = 1024
    /// The longest any AVFoundation step may take.
    static let timeout: Double = 20

    public enum Kind: Sendable { case picture, video }

    /// A source file as it really is: symlinks resolved once, its kind decided from the resolved
    /// file, so a link named `x.png` to a video is a video everywhere.
    public struct Inspected: Sendable {
        public let url: URL
        public let kind: Kind
        public let bytes: Int
    }

    public static func inspect(_ source: URL) throws -> Inspected {
        let url = source.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let bytes = values?.fileSize else { throw Failure.notAFile }
        return Inspected(url: url, kind: isVideoFile(url) ? .video : .picture, bytes: bytes)
    }

    /// Any movie file, playable or not: these go through `storeVideo`, which says why it refuses.
    public static func isVideoFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audiovisualContent) == true || videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Stores a picture or a video, whichever `source` is.
    public static func storeMedia(contentsOf source: URL, in dataFolder: URL) async throws -> Stored {
        let file = try inspect(source)
        return file.kind == .video ? try await storeVideo(file, in: dataFolder) : try storePicture(file, in: dataFolder)
    }

    /// Copies a playable video into the folder under a new name, as it is, off the caller's thread.
    static func storeVideo(_ file: Inspected, in dataFolder: URL) async throws -> Stored {
        let ext = file.url.pathExtension.lowercased()
        guard videoExtensions.contains(ext) else { throw Failure.notPlayable }
        guard file.bytes <= maximumVideoBytes else { throw Failure.tooLarge }
        guard let info = await videoInfo(file.url) else { throw Failure.notPlayable }
        let name = UUID().uuidString + "." + ext
        let destination = url(of: name, in: dataFolder)
        try FileManager.default.createDirectory(at: folder(in: dataFolder), withIntermediateDirectories: true)
        try await Task.detached { try copy(file.url, to: destination, limit: maximumVideoBytes) }.value
        return Stored(file: name, pixelSize: info.size, duration: info.duration)
    }

    /// Copies at most `limit` bytes: a file that grew past it since it was measured is refused
    /// and nothing is left behind.
    static func copy(_ source: URL, to destination: URL, limit: Int) throws {
        guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.missing }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else { throw Failure.missing }
        var written = 0
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                written += chunk.count
                guard written <= limit else { throw Failure.tooLarge }
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// The upright size and the length of a playable video whose frames decode through to the
    /// last one `readingVideo` samples (a truncated file fails here, not when an agent reads
    /// it); nil otherwise or after `timeout`.
    public static func videoInfo(_ url: URL) async -> (size: CGSize, duration: Double)? {
        await bounded {
            let asset = AVURLAsset(url: url)
            guard let (playable, duration) = try? await asset.load(.isPlayable, .duration), playable,
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let size = natural.applying(transform)
            let upright = CGSize(width: abs(size.width).rounded(), height: abs(size.height).rounded())
            let seconds = duration.seconds
            guard upright.width > 0, upright.height > 0, seconds.isFinite, seconds >= 0 else { return nil }
            let generator = exactGenerator(asset, side: 64)
            for second in [0, sampleTimes(duration: seconds).last ?? 0] {
                guard (try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))) != nil else { return nil }
            }
            return (upright, seconds)
        } ?? nil
    }

    /// The seconds `readingVideo` asks for: the middle of each of `readFrames` equal slices.
    static func sampleTimes(duration: Double) -> [Double] {
        (0..<readFrames).map { duration * (Double($0) + 0.5) / Double(readFrames) }
    }

    /// What an agent gets for a video: up to `readFrames` JPEG frames sampled evenly, each with
    /// the second it really shows. Times that land on the same frame give it once, so a
    /// one-frame video gives one frame. Nil when the file is gone, unplayable or too slow.
    public static func readingVideo(_ file: String, in dataFolder: URL) async -> [(second: Double, jpeg: Data)]? {
        let url = url(of: file, in: dataFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return await bounded { () -> [(second: Double, jpeg: Data)]? in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return nil }
            let generator = exactGenerator(asset, side: readFrameSide)
            var frames: [(second: Double, jpeg: Data)] = []
            for second in sampleTimes(duration: duration) {
                guard let (image, actual) = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)),
                      actual.seconds.isFinite, !frames.contains(where: { abs($0.second - actual.seconds) < 0.0005 }),
                      let jpeg = jpeg(image) else { continue }
                frames.append((actual.seconds, jpeg))
            }
            return frames.isEmpty ? nil : frames
        } ?? nil
    }

    /// A generator that returns the frame at the asked time, not the keyframe before it (the
    /// default tolerance is infinite, which on a screen recording's long GOP is the first frame).
    private static func exactGenerator(_ asset: AVAsset, side: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
    }

    /// `work`'s result, or nil when it takes longer than `seconds`. The caller goes on at the
    /// deadline even if AVFoundation ignores the cancellation.
    static func bounded<T: Sendable>(_ seconds: Double = timeout, _ work: @escaping @Sendable () async -> T) async -> T? {
        let gate = FirstResult<T>()
        return await withCheckedContinuation { continuation in
            gate.continuation = continuation
            let task = Task.detached { gate.resume(await work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                gate.resume(nil)
                task.cancel()
            }
        }
    }
}

/// Resumes its continuation once, with whichever result comes first.
private final class FirstResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T?, Never>?

    func resume(_ value: T?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
