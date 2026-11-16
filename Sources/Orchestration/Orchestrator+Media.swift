import Connections
import Foundation

/// Keeping the image and video records whole across older builds.
extension Orchestrator {
    /// At launch: videos an older build saved without their length get it back. Nothing the user
    /// named is rewritten (names are cleaned where they are shown and sent). Files in the images folder are never deleted
    /// here: a core whose database doesn't know them (a test, another build, a database that
    /// failed to open) can't tell an orphan from someone else's picture.
    func tidyMedia() {
        for record in images where record.isVideo && record.duration == nil {
            let url = ImageFiles.url(of: record.file, in: dataFolder)
            Task {
                guard let info = await ImageFiles.videoInfo(url) else { return }
                updateImage(record.id) { $0.duration = info.duration }
            }
        }
    }
}
