import Foundation
import ImageIO
import CoreGraphics
let dir = CommandLine.arguments[1]
let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpg") }.sorted()
var groups: [String: [Data]] = [:]
for f in files { let key = String(f.split(separator: "-").prefix(2).joined(separator: "-")); groups[key, default: []].append(try Data(contentsOf: URL(fileURLWithPath: dir + "/" + f))) }
let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
for (key, datas) in groups.sorted(by: { $0.key < $1.key }) {
    var w = 0, h = 0
    let runs = 300
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<runs {
        let src = CGImageSourceCreateWithData(datas[i % datas.count] as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, opts)!
        w = img.width; h = img.height
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(runs)
    print("\(key): \(w)x\(h) decode \(String(format: "%.2f", ms)) ms/frame -> \(String(format: "%.1f", ms * 60 / 10))% of a core at 60 fps")
}
