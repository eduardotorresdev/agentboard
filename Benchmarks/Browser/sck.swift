// Captures a window of another process with ScreenCaptureKit (public API) and reports frame rate.
import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit

_ = NSApplication.shared
let pid = pid_t(CommandLine.arguments[1])!
let seconds = 6.0
let interval = Int32(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "120")!
final class Output: NSObject, SCStreamOutput {
    var frames = 0, gaps: [Double] = [], last = 0.0, saved = false
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let now = CACurrentMediaTime()
        if last > 0 { gaps.append((now - last) * 1000) }
        last = now; frames += 1
        if !saved, frames == 30 {
            saved = true
            let image = CIImage(cvPixelBuffer: pixels)
            let rep = NSBitmapImageRep(ciImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "frame.png"))
            print("frame size", CVPixelBufferGetWidth(pixels), "x", CVPixelBufferGetHeight(pixels))
        }
    }
}
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
let windows = content.windows.filter { $0.owningApplication?.processID == pid }
for w in windows { print("window", w.windowID, w.frame, "onScreen", w.isOnScreen, "title", w.title ?? "") }
guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { print("no window"); exit(1) }
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
config.minimumFrameInterval = CMTime(value: 1, timescale: interval)
config.queueDepth = 4
config.showsCursor = false
let output = Output()
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
try await stream.startCapture()
try await Task.sleep(nanoseconds: 1_000_000_000)
output.frames = 0; output.gaps = []
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let cpu0 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
let t0 = CACurrentMediaTime()
try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
let wall = CACurrentMediaTime() - t0
getrusage(RUSAGE_SELF, &usage)
let cpu1 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
let gaps = output.gaps.sorted()
print(String(format: "delivered %.1f fps · gap p50 %.1f ms · p95 %.1f ms · capture process CPU %.1f%%", Double(output.frames) / wall,
             gaps.isEmpty ? 0 : gaps[gaps.count / 2], gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count) * 0.95)], (cpu1 - cpu0) / wall * 100))
try await stream.stopCapture()
