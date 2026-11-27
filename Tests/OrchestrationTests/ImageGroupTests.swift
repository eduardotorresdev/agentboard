import CoreGraphics
import Testing
@testable import Orchestration

@Test func aGroupLaysItsMembersOutOnItsGrid() {
    let pixels = [CGSize(width: 400, height: 200), CGSize(width: 300, height: 300)]
    let column = ImageGroup(direction: .vertical, origin: CGPoint(x: 10, y: 20), extent: 200, members: []).frames(for: pixels)
    #expect(column == [CGRect(x: 10, y: 20, width: 200, height: 100 + ImageRecord.titleHeight),
                       CGRect(x: 10, y: 136 + ImageRecord.titleHeight, width: 200, height: 200 + ImageRecord.titleHeight)])
    let row = ImageGroup(direction: .horizontal, origin: .zero, extent: 200, members: []).frames(for: pixels)
    #expect(row == [CGRect(x: 0, y: 0, width: 400, height: 200 + ImageRecord.titleHeight),
                    CGRect(x: 416, y: 0, width: 200, height: 200 + ImageRecord.titleHeight)])
}
