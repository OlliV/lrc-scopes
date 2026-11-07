import Foundation

/// ITU-R BT.709 luma / colour-difference math on gamma-encoded R'G'B' (0...1).
public enum Rec709 {
    public static let kr: Float = 0.2126
    public static let kg: Float = 0.7152
    public static let kb: Float = 0.0722
    /// 2 * (1 - kb)
    public static let cbDivisor: Float = 1.8556
    /// 2 * (1 - kr)
    public static let crDivisor: Float = 1.5748

    @inline(__always)
    public static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        kr * r + kg * g + kb * b
    }

    /// Returns (Y', Cb, Cr) with Y' in 0...1 and Cb, Cr in -0.5...0.5.
    @inline(__always)
    public static func ycbcr(_ r: Float, _ g: Float, _ b: Float) -> (y: Float, cb: Float, cr: Float) {
        let y = luma(r, g, b)
        return (y, (b - y) / cbDivisor, (r - y) / crDivisor)
    }

    /// Angle (degrees, counter-clockwise from the +Cb axis) of the "I" / skin tone
    /// line as conventionally drawn on vectorscopes.
    public static let skinToneAngleDegrees: Double = 123.0
}

/// The six colour bar targets drawn on the vectorscope graticule.
public struct VectorTarget: Equatable {
    public let label: String
    public let r: Float, g: Float, b: Float

    public static let primariesAndSecondaries: [VectorTarget] = [
        .init(label: "R", r: 1, g: 0, b: 0),
        .init(label: "Mg", r: 1, g: 0, b: 1),
        .init(label: "B", r: 0, g: 0, b: 1),
        .init(label: "Cy", r: 0, g: 1, b: 1),
        .init(label: "G", r: 0, g: 1, b: 0),
        .init(label: "Yl", r: 1, g: 1, b: 0),
    ]

    /// (Cb, Cr) for this target at the given bar amplitude (1.0 = 100% bars, 0.75 = 75% bars).
    public func chroma(amplitude: Float) -> (cb: Float, cr: Float) {
        let c = Rec709.ycbcr(r * amplitude, g * amplitude, b * amplitude)
        return (c.cb, c.cr)
    }
}
