@testable import AgentBoard
import XCTest

final class BlobStyleTests: XCTestCase {
    func testSeedsGiveStableRoundStyles() {
        var seen = Set<String>()
        for seed in UInt64(0) ..< 400 {
            let style = BlobStyle.make(seed: seed)
            XCTAssertEqual(style, BlobStyle.make(seed: seed), "pure")
            // The essence: a compact body, a little wider than tall.
            let ratio = style.bodySize.height / style.bodySize.width
            XCTAssert((0.65 ... 1).contains(ratio), "\(style)")
            seen.insert("\(style)")
        }
        XCTAssertGreaterThan(seen.count, 30, "seeds should vary the outfit")
    }

    func testNeverRepeatsThePreviousStyle() {
        for seed in UInt64(0) ..< 200 {
            let previous = BlobStyle.make(seed: seed)
            XCTAssertNotEqual(BlobStyle.make(seed: seed, avoiding: previous), previous)
        }
    }

    /// Always a drop: wider low than high, a rounded top (no point), eyes in the wide part.
    func testOutlinesAreDropsWithTheEyesInside() {
        let box = CGRect(x: 0, y: 0, width: 88, height: 76)
        for seed in UInt64(0) ..< 300 {
            for breath in [0.0, 0.5, 1.0] as [CGFloat] {
                for wobble in [-1.0, 0.0, 1.0] as [CGFloat] {
                    let path = BlobOutline.path(seed: seed, breath: breath, wobble: wobble, in: box)
                    let bounds = path.boundingRect
                    func span(at y: CGFloat) -> CGFloat {
                        let xs = stride(from: bounds.minX, through: bounds.maxX, by: 0.5).filter { path.contains(CGPoint(x: $0, y: y)) }
                        return (xs.max() ?? 0) - (xs.min() ?? 0)
                    }
                    let base = [0.55, 0.65, 0.75].map { span(at: bounds.minY + bounds.height * $0) }.max()!
                    XCTAssertGreaterThan(base, span(at: bounds.minY + bounds.height * 0.25) + 10, "seed \(seed): wider at the base")
                    // Rounded top: 5 pt below the top the drop is already wide, not a tip.
                    XCTAssertGreaterThan(span(at: bounds.minY + 5), 14, "seed \(seed): no point")
                    // Corners of both eyes (12x19, centers ±11, face offset 8) at either end of the ±8 look.
                    for x in [-25.0, -3.0, 3.0, 25.0] as [CGFloat] {
                        for y in [-1.5, 17.5] as [CGFloat] {
                            XCTAssert(path.contains(CGPoint(x: box.midX + x, y: box.midY + y)), "seed \(seed): eyes inside")
                        }
                    }
                }
            }
        }
    }
}
