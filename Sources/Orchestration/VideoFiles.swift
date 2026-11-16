import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Videos live with the pictures (same folder, same record), so a board that predates them
/// keeps its images as they are.
extension ImageFiles {
    /// The largest video taken: a few minutes of 1080p screen recording.
    public static let maximumVideoBytes = 200 * 1024 * 1024
    /// The containers AVFoundation plays without extra codecs.
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// How many frames `readingVideo` samples, evenly over the video.
    public static let readFrames = 4
    /// The longer side of each sampled frame.
    public static let readFrameSide = 1024

    /// Any movie file, playable or not: these go through `storeVideo`, which says why it refuses.
    public static func isVideoFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audiovisualContent) == true || videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Copies the video at `source` (`bytes` long) into the folder under a new name, as it is.
    static func storeVideo(at source: URL, bytes: Int, in dataFolder: URL) throws -> Stored {
        let ext = source.pathExtension.lowercased()
        guard videoExtensions.contains(ext) else { throw Failure.notPlayable }
        guard bytes <= maximumVideoBytes else { throw Failure.tooLarge }
        guard let info = videoInfo(source) else { throw Failure.notPlayable }
        let file = UUID().uuidString + "." + ext
        try FileManager.default.createDirectory(at: folder(in: dataFolder), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url(of: file, in: dataFolder))
        return Stored(file: file, pixelSize: info.size, duration: info.duration)
    }

    /// The upright size and the length of a playable video, nil otherwise.
    public static func videoInfo(_ url: URL) -> (size: CGSize, duration: Double)? {
        blocking {
            let asset = AVURLAsset(url: url)
            guard let (playable, duration) = try? await asset.load(.isPlayable, .duration), playable,
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let size = natural.applying(transform)
            let upright = CGSize(width: abs(size.width).rounded(), height: abs(size.height).rounded())
            guard upright.width > 0, upright.height > 0, duration.seconds.isFinite else { return nil }
            return (upright, max(0, duration.seconds))
        }
    }

    /// What an agent gets for a video: `readFrames` JPEG frames sampled evenly (at the middle of
    /// each equal slice), with the second each shows. Nil when the file is gone or unplayable.
    public static func readingVideo(_ file: String, in dataFolder: URL) -> [(second: Double, jpeg: Data)]? {
        let url = url(of: file, in: dataFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return blocking {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: readFrameSide, height: readFrameSide)
            var frames: [(Double, Data)] = []
            for index in 0..<readFrames {
                let second = duration * (Double(index) + 0.5) / Double(readFrames)
                guard let (image, _) = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)),
                      let jpeg = jpeg(image) else { continue }
                frames.append((second, jpeg))
            }
            return frames.isEmpty ? nil : frames
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
    }

    /// Runs AVFoundation's async loading to its end from synchronous code. The work runs
    /// detached, so waiting here (even on the main thread) can't deadlock it.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = BlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

private final class BlockingBox<T>: @unchecked Sendable {
    var value: T?
}
