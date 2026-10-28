import CoreGraphics
import Foundation
import ImageIO
import Metal

/// A window-sized render target so renderers can be measured without a window.
public final class Offscreen {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let texture: MTLTexture
    public let pass: MTLRenderPassDescriptor

    public init(width: Int, height: Int) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        texture = device.makeTexture(descriptor: descriptor)!
        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.98, green: 0.98, blue: 1, alpha: 1)
    }

    /// Saves what was last rendered, for looking at the result. `bottomUp` for renderers that
    /// put the first row at the bottom (Core Animation's `CARenderer`).
    public func writePNG(to url: URL, bottomUp: Bool = false) {
        let width = texture.width, height = texture.height, bytesPerRow = width * 4
        let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared)!
        let commands = queue.makeCommandBuffer()!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: buffer.contents(), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap),
              var image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        if bottomUp, let flipped = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap) {
            flipped.translateBy(x: 0, y: CGFloat(height))
            flipped.scaleBy(x: 1, y: -1)
            flipped.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = flipped.makeImage() ?? image
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
