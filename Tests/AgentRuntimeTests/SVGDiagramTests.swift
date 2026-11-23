import CoreGraphics
import Foundation
import Testing
@testable import AgentRuntime

private func fixture(_ name: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../core/fixtures/diagrams/\(name).svg"), encoding: .utf8)
}

/// The rendered pixels, to look at by point.
private struct Pixels {
    let width: Int, height: Int, scale: CGFloat
    let bytes: [UInt8]

    init(_ diagram: SVGDiagram, size: CGSize, scale: CGFloat) throws {
        let image = try #require(diagram.image(size: size, scale: scale))
        width = image.width; height = image.height; self.scale = scale
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    /// RGBA at a point (top left origin, in points).
    func at(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
        let px = Int(x * scale), py = Int(y * scale)
        let i = (py * width + px) * 4
        return Array(bytes[i..<i + 4])
    }

    /// Whether the pixel is close to `hex`, opaque.
    func isColor(_ x: CGFloat, _ y: CGFloat, _ hex: UInt32, tolerance: Int = 40) -> Bool {
        let p = at(x, y)
        let want = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        return p[3] > 200 && zip(p.prefix(3), want).allSatisfy { abs(Int($0) - $1) <= tolerance }
    }

    /// Columns (in points) holding pixels darker than `level` in a band of rows.
    func darkColumns(rows: ClosedRange<CGFloat>, level: Int = 120) -> ClosedRange<CGFloat>? {
        var low: Int?, high: Int?
        for py in Int(rows.lowerBound * scale)...Int(rows.upperBound * scale) {
            for px in 0..<width {
                let i = (py * width + px) * 4
                if bytes[i + 3] > 128, Int(bytes[i]) < level, Int(bytes[i + 1]) < level, Int(bytes[i + 2]) < level {
                    low = min(low ?? px, px); high = max(high ?? px, px)
                }
            }
        }
        guard let low, let high else { return nil }
        return CGFloat(low) / scale...CGFloat(high) / scale
    }
}

private func refusal(_ svg: String) -> String? {
    do { _ = try SVGDiagram(svg); return nil } catch let refused as SVGDiagram.Refused { return refused.reason } catch { return "\(error)" }
}

private func svg(_ body: String, viewBox: String = "0 0 100 100") -> String {
    #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="\#(viewBox)">\#(body)</svg>"#
}

@Suite struct SVGDiagramTests {
    /// The guide's example passes as it is, and draws its boxes, label and arrowhead.
    @Test func theGuidesExampleIsDrawn() throws {
        let diagram = try SVGDiagram(try fixture("guide"))
        #expect(diagram.viewBox == CGRect(x: 0, y: 0, width: 320, height: 120))
        let pixels = try Pixels(diagram, size: CGSize(width: 320, height: 120), scale: 2)
        #expect(pixels.isColor(30, 80, 0xE6F4FE))        // inside the left box
        #expect(pixels.isColor(10, 60, 0x0D74CE))        // its border
        #expect(pixels.at(2, 2)[3] == 0)                 // outside: clear
        #expect(pixels.isColor(205, 60, 0x1C2024))       // the arrowhead, just before the right box
        #expect(pixels.isColor(200, 57.5, 0x1C2024))     // wider than the 2-point line: the head
        let label = try #require(pixels.darkColumns(rows: 52...68))
        #expect(label.lowerBound < 60 && label.upperBound > 60)
    }

    /// Rounded corners, an arc, centered text and an arrowhead, sharp at 3x (drawn from the vector,
    /// not a scaled bitmap).
    @Test func shapesArcTextAndArrowAreDrawnAtAnyScale() throws {
        let diagram = try SVGDiagram(try fixture("shapes"))
        for scale in [1, 3] as [CGFloat] {
            let pixels = try Pixels(diagram, size: CGSize(width: 200, height: 120), scale: scale)
            #expect(pixels.isColor(50, 30, 0x0D74CE))            // the rounded rect
            #expect(!pixels.isColor(11, 11, 0x0D74CE))           // its corner is round
            #expect(pixels.isColor(140, 10.5, 0xE5484D, tolerance: 70)) // the arc's top
            #expect(!pixels.isColor(140, 50, 0xE5484D))          // it doesn't go round the bottom
            #expect(pixels.isColor(160, 102, 0x0090FF, tolerance: 60)) // the arrowhead
            let text = try #require(pixels.darkColumns(rows: 68...82))
            #expect(abs((text.lowerBound + text.upperBound) / 2 - 100) < 3, "text spans \(text)") // centered on x = 100
        }
        // At 3x the rect's left edge goes from clear to blue within one point.
        let sharp = try Pixels(diagram, size: CGSize(width: 200, height: 120), scale: 3)
        #expect(sharp.isColor(9.5, 30, 0xFFFFFF) && sharp.isColor(10.5, 30, 0x0D74CE))
    }

    @Test func pathsTakeEveryCommand() throws {
        #expect(refusal(svg(#"<path d="M10 10 h20 v20 H10 V10 l5 5 L20 20 c1 1 2 2 3 3 s1 1 2 2 C1 1 2 2 3 3 S1 1 2 2 q1 1 2 2 t1 1 Q1 1 2 2 T5 5 a5 5 0 0 1 10 0 A5 5 30 1 0 50 50 z m1-2.5.5.5e1-1E1 2"/>"#)) == nil)
        #expect(refusal(svg(#"<path d="M0 0 X 5 5"/>"#))?.contains("isn't a path command") == true)
        #expect(refusal(svg(#"<path d="L 5 5"/>"#))?.contains("start with a command") == true)
        #expect(refusal(svg(#"<path d="M0 0 A5 5 0 2 1 9 9"/>"#))?.contains("flags") == true)
    }

    /// What isn't drawn is refused with the reason; what can't change the drawing is ignored.
    @Test func whatIsntDrawnIsRefusedAndHarmlessAttributesIgnored() {
        #expect(refusal(svg(#"<rect width="5" height="5" id="a" class="box" data-x="1" onclick="x()"/><title>t</title>"#)) == nil)
        #expect(refusal(svg(#"<image href="a.png" width="5" height="5"/>"#))?.contains("`<image>` isn't drawn") == true)
        #expect(refusal(svg(#"<linearGradient id="g"/>"#))?.contains("solid colors") == true)
        #expect(refusal(svg(#"<style>rect{fill:red}</style>"#))?.contains("CSS") == true)
        #expect(refusal(svg(#"<rect width="5" height="5" style="fill:red"/>"#))?.contains("CSS") == true)
        #expect(refusal(svg(##"<rect width="5" height="5" fill="url(#g)"/>"##))?.contains("solid colors") == true)
        #expect(refusal(svg(#"<rect width="5" height="5" fill="rebeccapurple"/>"#))?.contains("#rrggbb") == true)
        #expect(refusal(svg(##"<rect width="5" height="5" filter="url(#f)"/>"##))?.contains("Filters") == true)
        #expect(refusal(svg(##"<line x2="5" y2="5" marker-start="url(#m)"/>"##))?.contains("Only `marker-end`") == true)
        #expect(refusal(svg(#"<text x="1" y="5">a<tspan>b</tspan></text>"#))?.contains("plain text") == true)
        #expect(refusal(svg(#"<rect width="50%" height="5"/>"#))?.contains("percentage") == true)
        #expect(refusal(svg(##"<line x2="5" y2="5" marker-end="url(#nope)"/>"##))?.contains("isn't a `<marker>`") == true)
        #expect(refusal(svg(#"<g transform="perspective(3)"/>"#))?.contains("transform") == true)
        #expect(refusal("<html/>")?.contains("one `<svg>`") == true)
        #expect(refusal("<svg") != nil)
    }

    // MARK: Limits against hostile or huge diagrams

    @Test func aDiagramOverTheByteCapIsRefused() {
        let filler = String(repeating: " ", count: SVGDiagram.maxBytes)
        #expect(refusal(svg(filler))?.contains("bytes") == true)
    }

    @Test func tooManyElementsAreRefused() {
        let many = String(repeating: #"<rect width="1" height="1"/>"#, count: SVGDiagram.maxElements + 1)
        #expect(refusal(svg(many))?.contains("more than \(SVGDiagram.maxElements) elements") == true)
        // Reuse can't multiply past the cap either: 10 × 10 × 10 × 10 copies of one rect.
        var body = #"<defs><rect id="l0" width="1" height="1"/>"#
        for level in 1...4 { body += ##"<g id="l\##(level)">"## + String(repeating: ##"<use href="#l\##(level - 1)"/>"##, count: 10) + "</g>" }
        body += ##"</defs><use href="#l4"/>"##
        #expect(refusal(svg(body))?.contains("`use` copies included") == true)
    }

    @Test func nestingDeeperThanTheCapIsRefused() {
        let depth = SVGDiagram.maxDepth + 1
        let deep = String(repeating: "<g>", count: depth) + String(repeating: "</g>", count: depth)
        #expect(refusal(svg(deep))?.contains("deeper than") == true)
        let fine = String(repeating: "<g>", count: SVGDiagram.maxDepth - 1) + String(repeating: "</g>", count: SVGDiagram.maxDepth - 1)
        #expect(refusal(svg(fine)) == nil)
    }

    @Test func aUseThatBringsItselfInIsRefused() {
        #expect(refusal(svg(##"<g id="a"><use href="#a"/></g>"##))?.contains("inside itself") == true)
        #expect(refusal(svg(##"<defs><g id="a"><use href="#b"/></g><g id="b"><use href="#a"/></g></defs><use href="#a"/>"##))?.contains("inside itself") == true)
        #expect(refusal(svg(#"<use href="https://example.com/x.svg#a"/>"#))?.contains("`#id`") == true)
    }

    @Test func everyNumberMustBeFinite() {
        #expect(refusal(svg(#"<rect width="inf" height="5"/>"#))?.contains("finite") == true)
        #expect(refusal(svg(#"<rect width="nan" height="5"/>"#))?.contains("finite") == true)
        #expect(refusal(svg(#"<rect width="1e999" height="5"/>"#))?.contains("finite") == true)
        #expect(refusal(svg(#"<path d="M0 0 L1e999 5"/>"#))?.contains("finite") == true)
    }

    @Test func theViewBoxNeedsAWidthAndHeight() {
        #expect(refusal(svg("", viewBox: "0 0 0 10"))?.contains("above 0") == true)
        #expect(refusal(svg("", viewBox: "0 0 10 -1"))?.contains("above 0") == true)
        #expect(refusal(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#)?.contains("above 0") == true)
        #expect(refusal(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"/>"#) == nil)
    }

    @Test func entitiesAreRefused() {
        let bomb = #"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaa">]><svg viewBox="0 0 1 1"><text>&a;</text></svg>"#
        #expect(refusal(bomb) != nil)
    }

    /// The cases both cores check (`core/fixtures/diagrams/cases.json`): the same SVG is drawn
    /// or refused, for the same reason, here and in the Rust core.
    @Test func theSharedCasesAreDrawnOrRefusedAlike() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../core/fixtures/diagrams/cases.json"))
        let cases = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cases"] as? [[String: Any]])
        #expect(cases.count > 40)
        for item in cases {
            let name = item["name"] as? String ?? ""
            let text: String
            if let file = item["file"] as? String {
                text = try fixture(String(file.dropLast(4)))
            } else if let parts = item["parts"] as? [[Any]] {
                text = parts.map { String(repeating: $0[0] as? String ?? "", count: $0[1] as? Int ?? 0) }.joined()
            } else {
                text = item["svg"] as? String ?? ""
            }
            #expect(refusal(text) == item["refused"] as? String, "\(name)")
        }
    }
}
