import Foundation

/// Raw (un-tone-mapped) waveform densities.
///
/// Storage is row-major with `level` as the row: `index = level * columns + column`,
/// where level 0 is black (0%) and `levels - 1` is white (100%).
public struct WaveformData {
    public let columns: Int
    public let levels: Int
    /// Number of image samples that fall into each column (image height * source
    /// columns per waveform column). Used to normalise density.
    public let samplesPerColumn: Int
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    public var luma: [UInt32]

    @inline(__always)
    public func index(column: Int, level: Int) -> Int { level * columns + column }
}

/// Raw vectorscope densities on a square `size * size` grid.
///
/// Row 0 is the *top* of the scope (+Cr), column 0 is the left (-Cb), so the
/// grid can be turned into an image directly.
public struct VectorscopeData {
    public let size: Int
    /// The chroma magnitude that maps to the edge of the grid (half its size).
    public let chromaAtEdge: Float
    public let totalSamples: Int
    public var density: [UInt32]
    /// Per-bin sum of the source R'G'B', used to colourise the trace.
    public var colorSum: [Float]

    /// Maps (Cb, Cr) to fractional grid coordinates (x right, y down).
    @inline(__always)
    public func gridPosition(cb: Float, cr: Float) -> (x: Float, y: Float) {
        let half = Float(size) / 2
        return (half + cb / chromaAtEdge * half, half - cr / chromaAtEdge * half)
    }
}

public struct ScopeAnalysis {
    public let waveform: WaveformData
    public let vectorscope: VectorscopeData
    public let imageWidth: Int
    public let imageHeight: Int
}

public struct ScopeAnalyzerConfiguration: Equatable {
    /// Vertical resolution of the waveform. 1024 matches a 10-bit scale.
    public var waveformLevels: Int = 1024
    /// Maximum number of waveform columns; the image is binned horizontally to fit.
    public var maxWaveformColumns: Int = 1024
    public var vectorscopeSize: Int = 512
    /// Chroma magnitude at the vectorscope edge at 1x. The most saturated 100% bar
    /// targets (magenta and green) have a chroma magnitude of ~0.595, so 0.68 keeps
    /// every 100% target and its label inside the graticule.
    public static let defaultChromaAtEdge: Float = 0.68
    public var vectorscopeChromaAtEdge: Float = ScopeAnalyzerConfiguration.defaultChromaAtEdge

    public init() {}
}

public enum ScopeAnalyzer {
    /// Computes waveform and vectorscope densities in a single pass over the image.
    public static func analyze(_ image: ImageBuffer, configuration: ScopeAnalyzerConfiguration = .init()) -> ScopeAnalysis {
        let width = image.width
        let height = image.height

        let columns = min(width, max(1, configuration.maxWaveformColumns))
        let levels = max(2, configuration.waveformLevels)
        let levelScale = Float(levels - 1)
        let maxLevel = levels - 1

        let vsSize = max(8, configuration.vectorscopeSize)
        let vsHalf = Float(vsSize) / 2
        let vsScale = vsHalf / configuration.vectorscopeChromaAtEdge

        var wfR = [UInt32](repeating: 0, count: columns * levels)
        var wfG = wfR, wfB = wfR, wfY = wfR
        var vsDensity = [UInt32](repeating: 0, count: vsSize * vsSize)
        var vsColor = [Float](repeating: 0, count: vsSize * vsSize * 3)

        // Precompute image column -> waveform column.
        var columnMap = [Int](repeating: 0, count: width)
        for x in 0..<width { columnMap[x] = min(columns - 1, x * columns / width) }

        @inline(__always)
        func level(_ v: Float) -> Int {
            // NaN-safe clamp: comparisons with NaN are false, so NaN maps to 0.
            let scaled = v * levelScale + 0.5
            if !(scaled > 0) { return 0 }
            let l = Int(scaled)
            return l > maxLevel ? maxLevel : l
        }

        image.pixels.withUnsafeBufferPointer { px in
            wfR.withUnsafeMutableBufferPointer { r in
            wfG.withUnsafeMutableBufferPointer { g in
            wfB.withUnsafeMutableBufferPointer { b in
            wfY.withUnsafeMutableBufferPointer { yy in
            vsDensity.withUnsafeMutableBufferPointer { vd in
            vsColor.withUnsafeMutableBufferPointer { vc in
                for y in 0..<height {
                    var p = y * width * 4
                    for x in 0..<width {
                        let rv = px[p], gv = px[p + 1], bv = px[p + 2]
                        p += 4
                        let col = columnMap[x]
                        let lum = Rec709.luma(rv, gv, bv)
                        r[level(rv) * columns + col] &+= 1
                        g[level(gv) * columns + col] &+= 1
                        b[level(bv) * columns + col] &+= 1
                        yy[level(lum) * columns + col] &+= 1

                        let cb = (bv - lum) / Rec709.cbDivisor
                        let cr = (rv - lum) / Rec709.crDivisor
                        let fx = vsHalf + cb * vsScale
                        let fy = vsHalf - cr * vsScale
                        guard fx >= 0, fy >= 0 else { continue }
                        let ix = Int(fx), iy = Int(fy)
                        guard ix < vsSize, iy < vsSize else { continue }
                        let bin = iy * vsSize + ix
                        vd[bin] &+= 1
                        vc[bin * 3] += rv
                        vc[bin * 3 + 1] += gv
                        vc[bin * 3 + 2] += bv
                    }
                }
            }}}}}}
        }

        let samplesPerColumn = height * max(1, (width + columns - 1) / columns)
        let waveform = WaveformData(columns: columns, levels: levels,
                                    samplesPerColumn: samplesPerColumn,
                                    red: wfR, green: wfG, blue: wfB, luma: wfY)
        let vectorscope = VectorscopeData(size: vsSize,
                                          chromaAtEdge: configuration.vectorscopeChromaAtEdge,
                                          totalSamples: width * height,
                                          density: vsDensity, colorSum: vsColor)
        return ScopeAnalysis(waveform: waveform, vectorscope: vectorscope,
                             imageWidth: width, imageHeight: height)
    }
}
