import AppKit
import SwiftUI

/// An organization's round avatar: its image, or its initial on its color.
struct OrganizationAvatar: View {
    let organization: Organization
    let size: CGFloat

    /// Avatar colors. No greens or teals; amber takes dark ink.
    static let palette: [(fill: Color, ink: Color)] = [
        (Theme.accent, .white),
        (Theme.secondary, .white),
        (Color(red: 0x00 / 255, green: 0x90 / 255, blue: 0xFF / 255), .white),
        (Color(red: 0xD6 / 255, green: 0x40 / 255, blue: 0x9F / 255), .white),
        (Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255), .white),
        (Color(red: 0x3E / 255, green: 0x63 / 255, blue: 0xDD / 255), .white),
        (Color(red: 0xFF / 255, green: 0xB2 / 255, blue: 0x24 / 255), Color(red: 0x4E / 255, green: 0x2A / 255, blue: 0x00 / 255)),
        (Color(red: 0xAD / 255, green: 0x7F / 255, blue: 0x58 / 255), .white),
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
        .clipShape(.circle)
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
