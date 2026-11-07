import CoreGraphics
import Foundation

public enum WaveformMode: String, CaseIterable, Codable {
    case rgbOverlay
    case rgbParade
    case luma

    public var displayName: String {
        switch self {
        case .rgbOverlay: return "RGB"
        case .rgbParade: return "Parade"
        case .luma: return "Luma"
        }
    }
}

/// An RGBA8 (premultiplied, opaque black background) raster.
public struct RGBA8Raster {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
    }

    public func makeCGImage(colorSpace: CGColorSpace = ImageDecoder.analysisColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

/// Converts raw densities into display rasters ("traces").
///
/// Density is tone mapped with `1 - exp(-gain * sqrt(d))`, where `d` is the bin
/// count normalised so that 1.0 means "as dense as a perfectly uniform spread".
/// The square root lifts sparse detail (single pixels stay visible, as on a
/// hardware scope) while `1 - exp` gives a soft shoulder instead of hard clipping.
public enum ScopeRenderer {
    public struct Style: Equatable {
        /// User "intensity" control, roughly 0.2 ... 4.
        public var gain: Float = 1.6
        public var colorizeVectorscope: Bool = true

        public init(gain: Float = 1.6, colorizeVectorscope: Bool = true) {
            self.gain = gain
            self.colorizeVectorscope = colorizeVectorscope
        }
    }

    // Trace tints. Not pure primaries: pure blue on black is too dark to read, and the
    // three tints still sum to (clipped) white where channels coincide.
    static let redTint: (Float, Float, Float) = (1.00, 0.22, 0.20)
    static let greenTint: (Float, Float, Float) = (0.25, 1.00, 0.25)
    static let blueTint: (Float, Float, Float) = (0.30, 0.45, 1.00)
    static let lumaTint: (Float, Float, Float) = (0.92, 0.95, 0.92)

    @inline(__always)
    static func toneMap(_ count: UInt32, norm: Float, gain: Float) -> Float {
        if count == 0 { return 0 }
        return 1 - expf(-gain * sqrtf(Float(count) * norm))
    }

    @inline(__always)
    static func byte(_ v: Float) -> UInt8 {
        if !(v > 0) { return 0 }
        if v >= 1 { return 255 }
        return UInt8(v * 255 + 0.5)
    }

    public static func renderWaveform(_ data: WaveformData, mode: WaveformMode, style: Style) -> RGBA8Raster {
        let cols = data.columns
        let levels = data.levels
        // d = count / (samplesPerColumn / levels)
        let norm = Float(levels) / Float(max(1, data.samplesPerColumn))
        let gain = style.gain

        switch mode {
        case .rgbOverlay, .luma:
            var out = RGBA8Raster(width: cols, height: levels)
            out.bytes.withUnsafeMutableBufferPointer { o in
                for level in 0..<levels {
                    let row = levels - 1 - level
                    for c in 0..<cols {
                        let i = level * cols + c
                        var r: Float, g: Float, b: Float
                        if mode == .luma {
                            let t = toneMap(data.luma[i], norm: norm, gain: gain)
                            if t == 0 { continue }
                            (r, g, b) = (lumaTint.0 * t, lumaTint.1 * t, lumaTint.2 * t)
                        } else {
                            let tr = toneMap(data.red[i], norm: norm, gain: gain)
                            let tg = toneMap(data.green[i], norm: norm, gain: gain)
                            let tb = toneMap(data.blue[i], norm: norm, gain: gain)
                            if tr == 0 && tg == 0 && tb == 0 { continue }
                            r = redTint.0 * tr + greenTint.0 * tg + blueTint.0 * tb
                            g = redTint.1 * tr + greenTint.1 * tg + blueTint.1 * tb
                            b = redTint.2 * tr + greenTint.2 * tg + blueTint.2 * tb
                        }
                        let p = (row * cols + c) * 4
                        o[p] = byte(r); o[p + 1] = byte(g); o[p + 2] = byte(b)
                    }
                }
            }
            return out

        case .rgbParade:
            let width = cols * 3
            var out = RGBA8Raster(width: width, height: levels)
            let channels: [([UInt32], (Float, Float, Float))] = [
                (data.red, redTint), (data.green, greenTint), (data.blue, blueTint),
            ]
            out.bytes.withUnsafeMutableBufferPointer { o in
                for (ci, (counts, tint)) in channels.enumerated() {
                    let xOffset = ci * cols
                    for level in 0..<levels {
                        let row = levels - 1 - level
                        for c in 0..<cols {
                            let t = toneMap(counts[level * cols + c], norm: norm, gain: gain)
                            if t == 0 { continue }
                            let p = (row * width + xOffset + c) * 4
                            o[p] = byte(tint.0 * t); o[p + 1] = byte(tint.1 * t); o[p + 2] = byte(tint.2 * t)
                        }
                    }
                }
            }
            return out
        }
    }

    public static func renderVectorscope(_ data: VectorscopeData, style: Style) -> RGBA8Raster {
        let n = data.size
        var out = RGBA8Raster(width: n, height: n)
        // Normalise so d = 1 when the image is spread uniformly over a disc covering
        // roughly 1/16 of the grid area (a realistic "busy" image), which keeps the
        // default gain looking similar to the waveform.
        let norm = Float(n * n) / 16 / Float(max(1, data.totalSamples))
        let gain = style.gain
        out.bytes.withUnsafeMutableBufferPointer { o in
            for i in 0..<(n * n) {
                let count = data.density[i]
                let t = toneMap(count, norm: norm, gain: gain)
                if t == 0 { continue }
                var r: Float, g: Float, b: Float
                if style.colorizeVectorscope {
                    // Average source colour of the bin, maximised so hue is legible
                    // regardless of the source brightness, then mixed with a little
                    // white so the trace never disappears on black.
                    let inv = 1 / Float(count)
                    var ar = data.colorSum[i * 3] * inv
                    var ag = data.colorSum[i * 3 + 1] * inv
                    var ab = data.colorSum[i * 3 + 2] * inv
                    let m = max(ar, ag, ab)
                    if m > 1e-4 { ar /= m; ag /= m; ab /= m } else { ar = 1; ag = 1; ab = 1 }
                    r = (0.75 * ar + 0.25) * t
                    g = (0.75 * ag + 0.25) * t
                    b = (0.75 * ab + 0.25) * t
                } else {
                    (r, g, b) = (lumaTint.0 * t, lumaTint.1 * t, lumaTint.2 * t)
                }
                let p = i * 4
                o[p] = byte(r); o[p + 1] = byte(g); o[p + 2] = byte(b)
            }
        }
        return out
    }
}
