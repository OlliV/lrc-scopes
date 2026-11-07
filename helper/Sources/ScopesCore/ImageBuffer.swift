import CoreGraphics
import Foundation
import ImageIO

/// An interleaved RGBA, 32-bit float image whose RGB values are *gamma encoded*
/// (R'G'B') in the analysis colour space, nominally in 0...1.
///
/// Scopes operate on encoded values, exactly like a broadcast waveform / vectorscope
/// operates on the encoded video signal (this is also what DaVinci Resolve shows).
public struct ImageBuffer {
    public let width: Int
    public let height: Int
    /// `width * height * 4` floats, row-major, top row first, RGBA.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0, "ImageBuffer must not be empty")
        precondition(pixels.count == width * height * 4, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Convenience for tests: builds a buffer from a closure returning (r, g, b).
    public init(width: Int, height: Int, _ generator: (_ x: Int, _ y: Int) -> (Float, Float, Float)) {
        var px = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = generator(x, y)
                let i = (y * width + x) * 4
                px[i] = r; px[i + 1] = g; px[i + 2] = b
            }
        }
        self.init(width: width, height: height, pixels: px)
    }
}

public enum ImageDecodingError: Error, CustomStringConvertible {
    case unreadable
    case noImage
    case contextCreationFailed

    public var description: String {
        switch self {
        case .unreadable: return "The image data could not be read."
        case .noImage: return "The image data contained no image."
        case .contextCreationFailed: return "Could not create a bitmap context for analysis."
        }
    }
}

public enum ImageDecoder {
    /// The colour space all analysis happens in. Lightroom previews are display
    /// referred; sRGB primaries + sRGB transfer is the closest match to what a
    /// Rec.709 scope in Resolve would see for a typical SDR timeline.
    public static let analysisColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Decodes JPEG (or any ImageIO supported) data, colour manages it into
    /// `analysisColorSpace` honouring any embedded ICC profile, and resamples it so
    /// that it fits within `maxDimension` (never upscales).
    public static func decode(data: Data, maxDimension: Int) throws -> ImageBuffer {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw ImageDecodingError.unreadable
        }
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw ImageDecodingError.noImage
        }
        return try render(image: image, maxDimension: maxDimension)
    }

    public static func render(image: CGImage, maxDimension: Int) throws -> ImageBuffer {
        let (w, h) = fittedSize(width: image.width, height: image.height, maxDimension: maxDimension)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        // 128 bpp float, premultiplied alpha (JPEGs are opaque, so this is lossless).
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 32,
                                      bytesPerRow: w * 16,
                                      space: analysisColorSpace,
                                      bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = .high
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ImageDecodingError.contextCreationFailed }
        return ImageBuffer(width: w, height: h, pixels: pixels)
    }

    static func fittedSize(width: Int, height: Int, maxDimension: Int) -> (Int, Int) {
        let longest = max(width, height)
        guard longest > maxDimension, maxDimension > 0 else { return (max(1, width), max(1, height)) }
        let scale = Double(maxDimension) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }
}
