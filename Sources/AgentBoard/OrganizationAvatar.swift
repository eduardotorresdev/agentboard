import AppKit
import SwiftUI

/// An organization's round avatar: its image, or its initial on its color.
struct OrganizationAvatar: View {
    let organization: Organization
    let size: CGFloat
    /// A rounded square with this corner instead of a circle.
    var corner: CGFloat?

    /// Avatar colors, from the app's blues and graphite; each initial passes AA on its fill.
    static let palette: [(fill: Color, ink: Color)] = [
        (Theme.accent, Theme.onAccent),
        (Theme.deep, Theme.onDeep),
        (Theme.accentTint, Theme.deep),
        (Theme.ink, Theme.window),
    ]

    /// The stored name, with the default organization's translated until the user renames it.
    static func displayName(_ organization: Organization) -> String {
        organization.isDefault && organization.name == "Default" ? L("Default") : organization.name
    }

    var body: some View {
        let colors = Self.palette[organization.color % Self.palette.count]
        Group {
            if let path = organization.icon, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(Self.displayName(organization).first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(colors.fill)
            }
        }
        .frame(width: size, height: size)
        // A circular rounded square of half the size is a circle.
        .clipShape(RoundedRectangle(cornerRadius: corner ?? size / 2, style: corner == nil ? .circular : .continuous))
    }
}

extension NSImage {
    /// The image cropped to a centered square and scaled to `side` points, as PNG data.
    func squarePNG(side: CGFloat) -> Data? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let length = min(source.width, source.height)
        let crop = CGRect(x: (source.width - length) / 2, y: (source.height - length) / 2, width: length, height: length)
        guard let square = source.cropping(to: crop) else { return nil }
        let pixels = Int(side * 2)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.imageInterpolation = .high
        context.cgContext.draw(square, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return bitmap.representation(using: .png, properties: [:])
    }
}
