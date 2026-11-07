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
        guard CGImageSourceGetCount(source) > 0 else { throw ImageDecodingError.noImage }

        // Lightroom's previews come pre-rotated without an orientation tag, but honour
        // one if present so the waveform's x axis always matches the picture.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation != 1 {
            let longest = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, longest),
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, options)
        }
        guard let image else { throw ImageDecodingError.noImage }
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

/// A region of interest in *normalised image coordinates*: origin top-left, x right,
/// y down, all values in 0...1. Normalised so it survives preview size changes.
public struct ScopeRegion: Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// Regions smaller than this (per side) are treated as accidental clicks.
    public static let minimumSide = 0.01

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The region spanned by two corner points (any order), clamped to the image.
    /// Returns nil when the result is too small to be a deliberate selection.
    public static func spanning(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> ScopeRegion? {
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        let x0 = clamp(min(a.x, b.x)), x1 = clamp(max(a.x, b.x))
        let y0 = clamp(min(a.y, b.y)), y1 = clamp(max(a.y, b.y))
        guard x1 - x0 >= minimumSide, y1 - y0 >= minimumSide else { return nil }
        return ScopeRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Integer pixel rectangle for an image of the given size; always at least 1x1 and
    /// fully inside the image.
    public func pixelRect(width w: Int, height h: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let x0 = min(w - 1, max(0, Int((x * Double(w)).rounded(.down))))
        let y0 = min(h - 1, max(0, Int((y * Double(h)).rounded(.down))))
        let x1 = min(w, max(x0 + 1, Int(((x + width) * Double(w)).rounded(.up))))
        let y1 = min(h, max(y0 + 1, Int(((y + height) * Double(h)).rounded(.up))))
        return (x0, y0, x1 - x0, y1 - y0)
    }
}

extension ImageBuffer {
    /// The pixels inside `region`.
    public func cropped(to region: ScopeRegion) -> ImageBuffer {
        let r = region.pixelRect(width: width, height: height)
        if r.x == 0 && r.y == 0 && r.width == width && r.height == height { return self }
        var out = [Float](repeating: 0, count: r.width * r.height * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<r.height {
                    let s = ((r.y + row) * width + r.x) * 4
                    let d = row * r.width * 4
                    for i in 0..<(r.width * 4) { dst[d + i] = src[s + i] }
                }
            }
        }
        return ImageBuffer(width: r.width, height: r.height, pixels: out)
    }

    /// An 8-bit sRGB image of this buffer, for display (e.g. the region navigator).
    public func makeDisplayImage() -> CGImage? {
        var raster = RGBA8Raster(width: width, height: height)
        raster.bytes.withUnsafeMutableBufferPointer { o in
            pixels.withUnsafeBufferPointer { p in
                for i in 0..<(width * height) {
                    for c in 0..<3 {
                        let v = p[i * 4 + c]
                        o[i * 4 + c] = v > 0 ? (v >= 1 ? 255 : UInt8(v * 255 + 0.5)) : 0
                    }
                }
            }
        }
        return raster.makeCGImage()
    }
}
