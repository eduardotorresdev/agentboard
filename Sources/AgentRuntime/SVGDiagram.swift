import CoreGraphics
import CoreText
import Foundation

/// A diagram an agent shows as decision evidence: the small SVG subset this file draws with
/// CoreGraphics, on the Mac and the phone alike. Checking a diagram is parsing it, so what passes
/// is by construction what gets drawn: anything outside the subset is refused with the reason,
/// never drawn half-way. Attributes it doesn't know are ignored when they can't change what is
/// drawn (ids, classes, titles), refused when they would (CSS, clips, filters, gradients).
public struct SVGDiagram: Equatable, Sendable {
    public struct Refused: Error, Equatable, Sendable {
        public let reason: String
    }

    public static let maxBytes = 65_536
    public static let maxElements = 2_000
    /// How deep `g`, `use` and `marker` may nest, counting what a `use` brings in.
    public static let maxDepth = 16

    /// The drawing's own coordinates, fitted into whatever size it is drawn at.
    public let viewBox: CGRect
    let items: [Item]

    public init(_ text: String) throws {
        try self.init(Data(text.utf8))
    }

    public init(_ data: Data) throws {
        guard data.count <= Self.maxBytes else {
            throw Refused(reason: "The diagram is \(data.count) bytes; the limit is \(Self.maxBytes). Draw less, or split it into cards.")
        }
        // No DTD at all: entities are the classic way to blow a small file up.
        guard data.range(of: Data("<!DOCTYPE".utf8)) == nil, data.range(of: Data("<!ENTITY".utf8)) == nil else {
            throw Refused(reason: "A diagram takes no DOCTYPE or entities.")
        }
        let root = try XMLTree.parse(data)
        guard root.name == "svg" else { throw Refused(reason: "A diagram is one `<svg>` element; this starts with `<\(root.name)>`.") }
        let box: CGRect
        if let text = root.attributes["viewBox"] {
            let values = try Numbers.list(text, "viewBox")
            guard values.count == 4 else { throw Refused(reason: "`viewBox` takes four numbers: x y width height.") }
            // CGRect would turn a negative size around: check the numbers as given.
            guard values[2] > 0, values[3] > 0 else { throw Refused(reason: "Give the diagram a `viewBox` with a width and height above 0.") }
            box = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else {
            box = CGRect(x: 0, y: 0, width: try Numbers.length(root.attributes["width"] ?? "0", "width"),
                         height: try Numbers.length(root.attributes["height"] ?? "0", "height"))
        }
        guard box.width > 0, box.height > 0 else {
            throw Refused(reason: "Give the diagram a `viewBox` (or `width` and `height`) with a width and height above 0.")
        }
        viewBox = box
        var builder = Builder(root: root)
        items = try builder.build()
    }

    /// Draws it fitted (aspect kept, centered) into `size`, in a context whose origin is the top
    /// left with y growing down.
    public func draw(in context: CGContext, size: CGSize) {
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        context.saveGState()
        context.translateBy(x: (size.width - viewBox.width * scale) / 2, y: (size.height - viewBox.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
        for item in items { item.draw(in: context) }
        context.restoreGState()
    }

    /// A bitmap of it at `size` points times `scale` pixels per point, on a clear background.
    public func image(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context, size: size)
        return context.makeImage()
    }
}

// MARK: - What gets drawn

struct RGBA: Equatable, Sendable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    func color(_ opacity: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a * opacity])!
    }
}

struct Style: Equatable, Sendable {
    var fill: RGBA? = RGBA(r: 0, g: 0, b: 0, a: 1)
    var stroke: RGBA?
    var strokeWidth: CGFloat = 1
    var dash: [CGFloat] = []
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var evenOdd = false
    var opacity: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var fontSize: CGFloat = 16
    var bold = false
    var anchor = "start"
    var markerEnd: String?
}

struct Marker: Equatable, Sendable {
    var box: CGRect
    var ref: CGPoint
    var size: CGSize
    var userSpace: Bool
    /// Nil: along the line (`auto`); else a fixed angle in degrees.
    var angle: CGFloat?
    var items: [Item]
}

enum Shape: Equatable, @unchecked Sendable {
    case path(CGPath, end: (point: CGPoint, direction: CGVector)?)
    case text(String, at: CGPoint)

    static func == (a: Shape, b: Shape) -> Bool {
        switch (a, b) {
        case let (.path(x, _), .path(y, _)): x == y
        case let (.text(s, p), .text(t, q)): s == t && p == q
        default: false
        }
    }
}

struct Item: Equatable, Sendable {
    var shape: Shape
    var transform: CGAffineTransform
    var style: Style
    var marker: Marker?

    func draw(in context: CGContext) {
        context.saveGState()
        context.concatenate(transform)
        context.setAlpha(style.opacity)
        switch shape {
        case let .path(path, end):
            if let fill = style.fill {
                context.addPath(path)
                context.setFillColor(fill.color(style.fillOpacity))
                context.fillPath(using: style.evenOdd ? .evenOdd : .winding)
            }
            if let stroke = style.stroke, style.strokeWidth > 0 {
                context.addPath(path)
                context.setStrokeColor(stroke.color(style.strokeOpacity))
                context.setLineWidth(style.strokeWidth)
                context.setLineCap(style.lineCap)
                context.setLineJoin(style.lineJoin)
                if !style.dash.isEmpty { context.setLineDash(phase: 0, lengths: style.dash) }
                context.strokePath()
            }
            if let marker, let end { drawMarker(marker, at: end.point, along: end.direction, in: context) }
        case let .text(string, at):
            guard let fill = style.fill else { break }
            let font = CTFontCreateUIFontForLanguage(style.bold ? .emphasizedSystem : .system, style.fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, style.fontSize, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill.color(style.fillOpacity),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = at.x - (style.anchor == "middle" ? width / 2 : style.anchor == "end" ? width : 0)
            context.translateBy(x: x, y: at.y)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private func drawMarker(_ marker: Marker, at point: CGPoint, along direction: CGVector, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        let angle = marker.angle.map { $0 * .pi / 180 } ?? atan2(direction.dy, direction.dx)
        context.rotate(by: angle)
        if !marker.userSpace { context.scaleBy(x: style.strokeWidth, y: style.strokeWidth) }
        context.scaleBy(x: marker.size.width / marker.box.width, y: marker.size.height / marker.box.height)
        context.translateBy(x: -marker.ref.x, y: -marker.ref.y)
        for item in marker.items { item.draw(in: context) }
        context.restoreGState()
    }
}

// MARK: - Reading the SVG

final class XMLTree {
    let name: String
    let attributes: [String: String]
    var children: [XMLTree] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) throws -> XMLTree {
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let refused = delegate.refused { throw refused }
        guard parsed, let root = delegate.root else {
            throw SVGDiagram.Refused(reason: "The diagram isn't well-formed XML\(parser.parserError.map { ": \($0.localizedDescription)" } ?? ".")")
        }
        return root
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []
        var count = 0
        var refused: SVGDiagram.Refused?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            count += 1
            if count > SVGDiagram.maxElements { return stop(parser, "The diagram has more than \(SVGDiagram.maxElements) elements. Draw less, or split it into cards.") }
            if stack.count >= SVGDiagram.maxDepth + 1 { return stop(parser, "The diagram nests deeper than \(SVGDiagram.maxDepth) levels. Flatten its groups.") }
            let node = XMLTree(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.text += String(decoding: data, as: UTF8.self) }
        func parser(_ parser: XMLParser, foundInternalSubset declaration: String?) { stop(parser, "A diagram takes no DOCTYPE or entities.") }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            if target != "xml" { stop(parser, "A diagram takes no processing instructions.") }
        }

        private func stop(_ parser: XMLParser, _ reason: String) {
            if refused == nil { refused = SVGDiagram.Refused(reason: reason) }
            parser.abortParsing()
        }
    }
}

enum Numbers {
    static func number(_ text: String, _ name: String) throws -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else {
            throw SVGDiagram.Refused(reason: "`\(name)` must be a finite number; it is “\(text)”.")
        }
        return CGFloat(value)
    }

    /// A length: a number, `px` allowed; other units and percentages are refused.
    static func length(_ text: String, _ name: String) throws -> CGFloat {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("px") { value.removeLast(2) }
        guard !value.hasSuffix("%") else { throw SVGDiagram.Refused(reason: "`\(name)` is a percentage; give it in the viewBox's units.") }
        return try number(value, name)
    }

    static func list(_ text: String, _ name: String) throws -> [CGFloat] {
        try text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { try number(String($0), name) }
    }
}

struct Builder {
    let root: XMLTree
    private var ids: [String: XMLTree] = [:]
    private var markers: [String: Marker] = [:]
    /// The `use` targets being expanded, to refuse one that brings itself in.
    private var expanding: Set<String> = []
    /// Elements drawn so far, `use` copies included, so reuse can't multiply past the cap.
    private var drawnCount = 0

    /// Elements that draw or hold others; `title`, `desc` and `metadata` are read and skipped.
    static let drawn: Set<String> = ["g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "use", "defs"]
    static let skipped: Set<String> = ["title", "desc", "metadata"]
    /// Attributes that would change the drawing in ways this file doesn't draw.
    static let refusedAttributes: [String: String] = [
        "style": "CSS isn't drawn: give `fill`, `stroke` and the rest as attributes.",
        "clip-path": "Clipping isn't drawn.", "mask": "Masks aren't drawn.", "filter": "Filters (blur, shadow) aren't drawn.",
        "marker-start": "Only `marker-end` is drawn.", "marker-mid": "Only `marker-end` is drawn.", "marker": "Only `marker-end` is drawn.",
        "visibility": "`visibility` isn't drawn: leave the element out.", "display": "`display` isn't drawn: leave the element out.",
        "font-style": "Text is drawn in the system font, upright.", "writing-mode": "Text is drawn left to right.",
        "lengthAdjust": "Text keeps its own width.", "textLength": "Text keeps its own width.",
        "paint-order": "Fill is drawn before stroke.", "vector-effect": "`vector-effect` isn't drawn.",
    ]

    init(root: XMLTree) {
        self.root = root
    }

    mutating func build() throws -> [Item] {
        func collect(_ node: XMLTree) {
            if let id = node.attributes["id"] { ids[id] = node }
            node.children.forEach(collect)
        }
        collect(root)
        return try children(of: root, transform: .identity, style: Style(), depth: 0)
    }

    private mutating func children(of node: XMLTree, transform: CGAffineTransform, style: Style, depth: Int) throws -> [Item] {
        var items: [Item] = []
        for child in node.children {
            items += try element(child, transform: transform, style: style, depth: depth + 1)
        }
        return items
    }

    private mutating func element(_ node: XMLTree, transform parent: CGAffineTransform, style inherited: Style, depth: Int) throws -> [Item] {
        if Self.skipped.contains(node.name) { return [] }
        if node.name == "marker" {
            guard node.attributes["id"] != nil else { throw SVGDiagram.Refused(reason: "A `<marker>` needs an `id` for `marker-end` to name it.") }
            return []
        }
        guard Self.drawn.contains(node.name) else {
            let hint = switch node.name {
            case "linearGradient", "radialGradient", "pattern": " Fills are solid colors."
            case "image", "foreignObject": " A diagram draws shapes and text only."
            case "tspan", "textPath": " Text is one `<text>` per line."
            case "style": " CSS isn't drawn: give colors as attributes."
            case "svg": " Nest groups (`<g>`), not another `<svg>`."
            default: ""
            }
            throw SVGDiagram.Refused(reason: "`<\(node.name)>` isn't drawn.\(hint)")
        }
        guard depth <= SVGDiagram.maxDepth else {
            throw SVGDiagram.Refused(reason: "The diagram nests deeper than \(SVGDiagram.maxDepth) levels. Flatten its groups.")
        }
        if node.name == "defs" { return [] }
        drawnCount += 1
        guard drawnCount <= SVGDiagram.maxElements else {
            throw SVGDiagram.Refused(reason: "The diagram draws more than \(SVGDiagram.maxElements) elements, `use` copies included. Draw less.")
        }
        let attributes = node.attributes
        for name in attributes.keys {
            if let reason = Self.refusedAttributes[name] { throw SVGDiagram.Refused(reason: "`\(name)` on `<\(node.name)>`: \(reason)") }
        }
        let transform = try Self.transform(attributes["transform"]).concatenating(parent)
        let style = try self.style(attributes, inheriting: inherited, on: node.name)
        func number(_ name: String, _ fallback: CGFloat = 0) throws -> CGFloat {
            try attributes[name].map { try Numbers.length($0, name) } ?? fallback
        }

        let marker = try style.markerEnd.map { try self.marker($0) }
        func item(_ path: CGPath, end: (CGPoint, CGVector)? = nil) -> Item {
            Item(shape: .path(path, end: end.map { (point: $0.0, direction: $0.1) }), transform: transform, style: style, marker: end == nil ? nil : marker)
        }
        switch node.name {
        case "g":
            return try children(of: node, transform: transform, style: style, depth: depth)
        case "use":
            guard let reference = attributes["href"] ?? attributes["xlink:href"], reference.hasPrefix("#") else {
                throw SVGDiagram.Refused(reason: "`<use>` takes an `href` to an element of the diagram (`#id`).")
            }
            let id = String(reference.dropFirst())
            guard let target = ids[id] else { throw SVGDiagram.Refused(reason: "`<use>` names `#\(id)`, which the diagram doesn't have.") }
            guard !expanding.contains(id) else { throw SVGDiagram.Refused(reason: "`<use>` brings in `#\(id)` inside itself.") }
            let moved = CGAffineTransform(translationX: try number("x"), y: try number("y")).concatenating(transform)
            expanding.insert(id)
            defer { expanding.remove(id) }
            return try element(target, transform: moved, style: style, depth: depth + 1)
        case "rect":
            let rect = CGRect(x: try number("x"), y: try number("y"), width: try number("width"), height: try number("height"))
            guard rect.width >= 0, rect.height >= 0 else { throw SVGDiagram.Refused(reason: "A `<rect>` has a negative size.") }
            var rx = try attributes["rx"].map { try Numbers.length($0, "rx") }
            var ry = try attributes["ry"].map { try Numbers.length($0, "ry") }
            rx = rx ?? ry; ry = ry ?? rx
            let cornerX = min(max(rx ?? 0, 0), rect.width / 2), cornerY = min(max(ry ?? 0, 0), rect.height / 2)
            return [item(CGPath(roundedRect: rect, cornerWidth: cornerX, cornerHeight: cornerY, transform: nil))]
        case "circle":
            let r = try number("r")
            return [item(CGPath(ellipseIn: CGRect(x: try number("cx") - r, y: try number("cy") - r, width: 2 * r, height: 2 * r), transform: nil))]
        case "ellipse":
            let rx = try number("rx"), ry = try number("ry")
            return [item(CGPath(ellipseIn: CGRect(x: try number("cx") - rx, y: try number("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil))]
        case "line":
            let a = CGPoint(x: try number("x1"), y: try number("y1")), b = CGPoint(x: try number("x2"), y: try number("y2"))
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            return [item(path, end: (b, CGVector(dx: b.x - a.x, dy: b.y - a.y)))]
        case "polyline", "polygon":
            let values = try Numbers.list(attributes["points"] ?? "", "points")
            guard values.count >= 4, values.count.isMultiple(of: 2) else {
                throw SVGDiagram.Refused(reason: "`points` on `<\(node.name)>` takes pairs of numbers, at least two points.")
            }
            let points = stride(from: 0, to: values.count, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
            let path = CGMutablePath()
            path.addLines(between: points)
            if node.name == "polygon" { path.closeSubpath() }
            let last = points[points.count - 1], before = node.name == "polygon" ? last : points[points.count - 2]
            let end = node.name == "polygon" ? (points[0], CGVector(dx: points[0].x - before.x, dy: points[0].y - before.y))
                : (last, CGVector(dx: last.x - before.x, dy: last.y - before.y))
            return [item(path, end: end)]
        case "path":
            let parsed = try PathData.parse(attributes["d"] ?? "")
            return [item(parsed.path, end: parsed.end)]
        case "text":
            guard node.children.isEmpty else { throw SVGDiagram.Refused(reason: "`<text>` holds plain text only; one `<text>` per line.") }
            for name in ["x", "y"] where (attributes[name] ?? "").contains(where: { $0 == " " || $0 == "," }) {
                throw SVGDiagram.Refused(reason: "`\(name)` on `<text>` takes one number.")
            }
            let string = node.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return string.isEmpty ? [] : [Item(shape: .text(string, at: CGPoint(x: try number("x"), y: try number("y"))), transform: transform, style: style, marker: nil)]
        default:
            return []
        }
    }

    private mutating func marker(_ reference: String) throws -> Marker {
        let id = try Self.url(reference, "marker-end")
        if let known = markers[id] { return known }
        guard let node = ids[id], node.name == "marker" else {
            throw SVGDiagram.Refused(reason: "`marker-end` names `#\(id)`, which isn't a `<marker>` of the diagram.")
        }
        guard !expanding.contains(id) else { throw SVGDiagram.Refused(reason: "The marker `#\(id)` uses itself.") }
        let attributes = node.attributes
        func number(_ name: String, _ fallback: CGFloat) throws -> CGFloat {
            try attributes[name].map { try Numbers.length($0, name) } ?? fallback
        }
        let size = CGSize(width: try number("markerWidth", 3), height: try number("markerHeight", 3))
        var box = CGRect(origin: .zero, size: size)
        if let text = attributes["viewBox"] {
            let values = try Numbers.list(text, "viewBox")
            guard values.count == 4, values[2] > 0, values[3] > 0 else { throw SVGDiagram.Refused(reason: "A marker's `viewBox` takes four numbers with a width and height above 0.") }
            box = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        guard size.width > 0, size.height > 0 else { throw SVGDiagram.Refused(reason: "A marker needs a `markerWidth` and `markerHeight` above 0.") }
        let orient = attributes["orient"] ?? "0"
        let angle: CGFloat? = orient == "auto" ? nil : try Numbers.number(orient.replacingOccurrences(of: "deg", with: ""), "orient")
        let units = attributes["markerUnits"] ?? "strokeWidth"
        guard ["strokeWidth", "userSpaceOnUse"].contains(units) else { throw SVGDiagram.Refused(reason: "`markerUnits` is strokeWidth or userSpaceOnUse.") }
        expanding.insert(id)
        defer { expanding.remove(id) }
        var inner = Style()
        inner = try style(attributes, inheriting: inner, on: "marker")
        let items = try children(of: node, transform: .identity, style: inner, depth: 1)
        let marker = Marker(box: box, ref: CGPoint(x: try number("refX", 0), y: try number("refY", 0)), size: size,
                            userSpace: units == "userSpaceOnUse", angle: angle, items: items)
        markers[id] = marker
        return marker
    }

    private func style(_ attributes: [String: String], inheriting inherited: Style, on element: String) throws -> Style {
        var style = inherited
        style.markerEnd = nil
        if let value = attributes["fill"] { style.fill = try Self.paint(value, "fill") }
        if let value = attributes["stroke"] { style.stroke = try Self.paint(value, "stroke") }
        if let value = attributes["stroke-width"] { style.strokeWidth = max(0, try Numbers.length(value, "stroke-width")) }
        if let value = attributes["stroke-dasharray"] {
            style.dash = value == "none" ? [] : try Numbers.list(value, "stroke-dasharray")
            guard style.dash.allSatisfy({ $0 >= 0 }) else { throw SVGDiagram.Refused(reason: "`stroke-dasharray` takes lengths of 0 or more.") }
        }
        if let value = attributes["stroke-linecap"] {
            guard let cap = ["butt": CGLineCap.butt, "round": .round, "square": .square][value] else { throw SVGDiagram.Refused(reason: "`stroke-linecap` is butt, round or square.") }
            style.lineCap = cap
        }
        if let value = attributes["stroke-linejoin"] {
            guard let join = ["miter": CGLineJoin.miter, "round": .round, "bevel": .bevel][value] else { throw SVGDiagram.Refused(reason: "`stroke-linejoin` is miter, round or bevel.") }
            style.lineJoin = join
        }
        if let value = attributes["fill-rule"] {
            guard ["nonzero", "evenodd"].contains(value) else { throw SVGDiagram.Refused(reason: "`fill-rule` is nonzero or evenodd.") }
            style.evenOdd = value == "evenodd"
        }
        func unit(_ name: String) throws -> CGFloat? {
            try attributes[name].map { min(1, max(0, try Numbers.number($0, name))) }
        }
        // shortcut: a group's opacity multiplies into each child, so overlapping children show through each other; draw a layer per group if that matters.
        style.opacity = inherited.opacity * (try unit("opacity") ?? 1)
        if let value = try unit("fill-opacity") { style.fillOpacity = value }
        if let value = try unit("stroke-opacity") { style.strokeOpacity = value }
        if let value = attributes["font-size"] {
            style.fontSize = try Numbers.length(value, "font-size")
            guard style.fontSize > 0 else { throw SVGDiagram.Refused(reason: "`font-size` must be above 0.") }
        }
        if let value = attributes["font-weight"] {
            if let weight = Double(value) { style.bold = weight >= 600 } else {
                guard ["normal", "bold", "bolder", "lighter"].contains(value) else { throw SVGDiagram.Refused(reason: "`font-weight` is normal, bold or a number.") }
                style.bold = value == "bold" || value == "bolder"
            }
        }
        if let value = attributes["text-anchor"] {
            guard ["start", "middle", "end"].contains(value) else { throw SVGDiagram.Refused(reason: "`text-anchor` is start, middle or end.") }
            style.anchor = value
        }
        if let value = attributes["marker-end"], value != "none" { style.markerEnd = value }
        return style
    }

    static func url(_ value: String, _ name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("url(#"), trimmed.hasSuffix(")") else {
            throw SVGDiagram.Refused(reason: "`\(name)` takes `url(#id)` naming a `<marker>` of the diagram.")
        }
        return String(trimmed.dropFirst(5).dropLast())
    }

    static let named: [String: RGBA] = [
        "black": RGBA(r: 0, g: 0, b: 0, a: 1), "white": RGBA(r: 1, g: 1, b: 1, a: 1),
        "transparent": RGBA(r: 0, g: 0, b: 0, a: 0),
    ]

    static func paint(_ value: String, _ name: String) throws -> RGBA? {
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" { return nil }
        if let color = named[value] { return color }
        if value.hasPrefix("url(") { throw SVGDiagram.Refused(reason: "`\(name)` is a gradient or pattern; fills are solid colors (`#rrggbb`).") }
        guard value.hasPrefix("#"), let hex = UInt32(value.dropFirst(), radix: 16) else {
            throw SVGDiagram.Refused(reason: "`\(name)` is “\(value)”: give a color as `#rrggbb`, `#rgb`, black, white or none.")
        }
        switch value.count {
        case 7: return RGBA(r: CGFloat(hex >> 16 & 0xFF) / 255, g: CGFloat(hex >> 8 & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255, a: 1)
        case 4: return RGBA(r: CGFloat(hex >> 8 & 0xF) / 15, g: CGFloat(hex >> 4 & 0xF) / 15, b: CGFloat(hex & 0xF) / 15, a: 1)
        default: throw SVGDiagram.Refused(reason: "`\(name)` is “\(value)”: give a color as `#rrggbb` or `#rgb`.")
        }
    }

    static func transform(_ value: String?) throws -> CGAffineTransform {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return .identity }
        var result = CGAffineTransform.identity
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "(") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n"))
            guard let close = rest[open...].firstIndex(of: ")") else { throw SVGDiagram.Refused(reason: "`transform` is missing a “)”.") }
            let values = try Numbers.list(String(rest[rest.index(after: open)..<close]), "transform")
            let step: CGAffineTransform
            switch (name, values.count) {
            case ("translate", 1): step = CGAffineTransform(translationX: values[0], y: 0)
            case ("translate", 2): step = CGAffineTransform(translationX: values[0], y: values[1])
            case ("scale", 1): step = CGAffineTransform(scaleX: values[0], y: values[0])
            case ("scale", 2): step = CGAffineTransform(scaleX: values[0], y: values[1])
            case ("rotate", 1): step = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
            case ("rotate", 3):
                step = CGAffineTransform(translationX: -values[1], y: -values[2])
                    .concatenating(CGAffineTransform(rotationAngle: values[0] * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: values[1], y: values[2]))
            case ("skewX", 1): step = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): step = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            case ("matrix", 6): step = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            default: throw SVGDiagram.Refused(reason: "`transform` has “\(name)” with \(values.count) numbers; it takes translate, scale, rotate, skewX, skewY or matrix.")
            }
            // Listed transforms apply right to left: the last one first.
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        guard rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n")).isEmpty else {
            throw SVGDiagram.Refused(reason: "`transform` has something after its last “)”.")
        }
        return result
    }
}

/// A path's `d`, every command, arcs included.
enum PathData {
    static func parse(_ d: String) throws -> (path: CGPath, end: (CGPoint, CGVector)?) {
        var scanner = Lexer(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastQuad: CGPoint?
        var direction = CGVector.zero
        var command: UInt8?
        var any = false
        func fail(_ reason: String) -> SVGDiagram.Refused { SVGDiagram.Refused(reason: "`d` on `<path>`: \(reason)") }
        while true {
            scanner.skipSeparators()
            guard !scanner.atEnd else { break }
            if let letter = scanner.letter() {
                guard Array("MmLlHhVvCcSsQqTtAaZz".utf8).contains(letter) else { throw fail("“\(Character(UnicodeScalar(letter)))” isn't a path command.") }
                command = letter
            } else if command == nil {
                throw fail("it must start with a command (M).")
            }
            guard let letter = command else { break }
            let relative = letter >= 97
            let base = relative ? current : .zero
            func n() throws -> CGFloat {
                guard let value = scanner.number() else { throw fail("a command is missing its numbers.") }
                guard value.isFinite else { throw fail("numbers must be finite.") }
                return value
            }
            func point() throws -> CGPoint { CGPoint(x: try n() + base.x, y: try n() + base.y) }
            if !any, letter != 77, letter != 109 { throw fail("it must start with a command (M).") }
            any = true
            var control: CGPoint?, quad: CGPoint?
            switch letter {
            case 77, 109:
                current = try point(); start = current
                path.move(to: current)
                command = relative ? 108 : 76 // further pairs are lines
            case 76, 108:
                let p = try point(); direction = CGVector(dx: p.x - current.x, dy: p.y - current.y)
                path.addLine(to: p); current = p
            case 72, 104:
                let p = CGPoint(x: try n() + (relative ? current.x : 0), y: current.y); direction = CGVector(dx: p.x - current.x, dy: 0)
                path.addLine(to: p); current = p
            case 86, 118:
                let p = CGPoint(x: current.x, y: try n() + (relative ? current.y : 0)); direction = CGVector(dx: 0, dy: p.y - current.y)
                path.addLine(to: p); current = p
            case 67, 99:
                let c1 = try point(), c2 = try point(), p = try point()
                path.addCurve(to: p, control1: c1, control2: c2)
                direction = CGVector(dx: p.x - c2.x, dy: p.y - c2.y); control = c2; current = p
            case 83, 115:
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = try point(), p = try point()
                path.addCurve(to: p, control1: c1, control2: c2)
                direction = CGVector(dx: p.x - c2.x, dy: p.y - c2.y); control = c2; current = p
            case 81, 113:
                let c = try point(), p = try point()
                path.addQuadCurve(to: p, control: c)
                direction = CGVector(dx: p.x - c.x, dy: p.y - c.y); quad = c; current = p
            case 84, 116:
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let p = try point()
                path.addQuadCurve(to: p, control: c)
                direction = CGVector(dx: p.x - c.x, dy: p.y - c.y); quad = c; current = p
            case 65, 97:
                let rx = abs(try n()), ry = abs(try n()), rotation = try n()
                guard let large = scanner.flag(), let sweep = scanner.flag() else { throw fail("an arc's flags are 0 or 1.") }
                let p = try point()
                direction = arc(path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep) ?? CGVector(dx: p.x - current.x, dy: p.y - current.y)
                current = p
            case 90, 122:
                direction = CGVector(dx: start.x - current.x, dy: start.y - current.y)
                path.closeSubpath(); current = start
                command = nil
            default: break
            }
            lastControl = control
            lastQuad = quad
        }
        guard any else { throw fail("it is empty.") }
        return (path, (current, direction))
    }

    /// Adds an SVG arc (endpoint form) and returns the direction it ends in; nil when it is a line.
    static func arc(_ path: CGMutablePath, from a: CGPoint, to b: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) -> CGVector? {
        guard rx > 0, ry > 0, a != b else { path.addLine(to: b); return nil }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        var rx = rx, ry = ry
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, numerator / denominator))
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (a.x + b.x) / 2, y: sinPhi * cx1 + cosPhi * cy1 + (a.y + b.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat { atan2(uy, ux) }
        let start = angle((x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((-x1 - cx1) / rx, (-y1 - cy1) / ry) - start
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        let transform = CGAffineTransform(scaleX: rx, y: ry).concatenating(CGAffineTransform(rotationAngle: phi))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        path.addRelativeArc(center: .zero, radius: 1, startAngle: start, delta: delta, transform: transform)
        // The tangent at the end: perpendicular to the radius, in the sweep's direction.
        let end = start + delta, sign: CGFloat = delta >= 0 ? 1 : -1
        let tangent = CGVector(dx: -sin(end) * rx * sign, dy: cos(end) * ry * sign)
        return CGVector(dx: cosPhi * tangent.dx - sinPhi * tangent.dy, dy: sinPhi * tangent.dx + cosPhi * tangent.dy)
    }

    struct Lexer {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { index >= bytes.count }

        mutating func skipSeparators() {
            while index < bytes.count, [32, 9, 10, 13, 44].contains(bytes[index]) { index += 1 }
        }

        mutating func letter() -> UInt8? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard (65...90).contains(byte) || (97...122).contains(byte), byte != 101, byte != 69 else { return nil }
            index += 1
            return byte
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
            index += 1
            return bytes[index - 1] == 49
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            var digits = false, dot = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) { digits = true; index += 1 } else if byte == 46, !dot { dot = true; index += 1 } else { break }
            }
            if digits, index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                var look = index + 1
                if look < bytes.count, bytes[look] == 43 || bytes[look] == 45 { look += 1 }
                if look < bytes.count, (48...57).contains(bytes[look]) {
                    index = look
                    while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                }
            }
            guard digits, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else { index = begin; return nil }
            return CGFloat(value)
        }
    }
}
