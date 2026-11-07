import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScopesCore

final class ColorMathTests: XCTestCase {
    func testLumaCoefficientsSumToOne() {
        XCTAssertEqual(Rec709.kr + Rec709.kg + Rec709.kb, 1, accuracy: 1e-6)
        XCTAssertEqual(Rec709.luma(1, 1, 1), 1, accuracy: 1e-6)
    }

    func testNeutralHasNoChroma() {
        for v: Float in [0, 0.18, 0.5, 1] {
            let c = Rec709.ycbcr(v, v, v)
            XCTAssertEqual(c.cb, 0, accuracy: 1e-6)
            XCTAssertEqual(c.cr, 0, accuracy: 1e-6)
        }
    }

    func testPrimaryChromaMatchesBT709() {
        // Reference values from BT.709 (full-range, normalised).
        let red = Rec709.ycbcr(1, 0, 0)
        XCTAssertEqual(red.y, 0.2126, accuracy: 1e-4)
        XCTAssertEqual(red.cb, -0.1146, accuracy: 1e-4)
        XCTAssertEqual(red.cr, 0.5, accuracy: 1e-4)
        let blue = Rec709.ycbcr(0, 0, 1)
        XCTAssertEqual(blue.cb, 0.5, accuracy: 1e-4)
        XCTAssertEqual(blue.cr, -0.0459, accuracy: 1e-4)
    }

    func testSkinToneLineLiesBetweenRedAndYellow() {
        func angle(_ t: VectorTarget) -> Double {
            let c = t.chroma(amplitude: 1)
            var a = atan2(Double(c.cr), Double(c.cb)) * 180 / .pi
            if a < 0 { a += 360 }
            return a
        }
        let targets = Dictionary(uniqueKeysWithValues: VectorTarget.primariesAndSecondaries.map { ($0.label, $0) })
        XCTAssertLessThan(angle(targets["R"]!), Rec709.skinToneAngleDegrees)
        XCTAssertGreaterThan(angle(targets["Yl"]!), Rec709.skinToneAngleDegrees)
    }
}

final class AnalyzerTests: XCTestCase {
    private var config: ScopeAnalyzerConfiguration {
        var c = ScopeAnalyzerConfiguration()
        c.waveformLevels = 1024
        c.maxWaveformColumns = 64
        c.vectorscopeSize = 256
        c.sourceQuantizationStep = 0 // exact-bin assertions
        return c
    }

    func testBlackAndWhiteLandOnWaveformExtremes() {
        // Left half black, right half white.
        let img = ImageBuffer(width: 64, height: 10) { x, _ in x < 32 ? (0, 0, 0) : (1, 1, 1) }
        let a = ScopeAnalyzer.analyze(img, configuration: config)
        let wf = a.waveform
        XCTAssertEqual(wf.columns, 64)
        for c in 0..<64 {
            let expectedLevel = c < 32 ? 0 : wf.levels - 1
            for ch in [wf.red, wf.green, wf.blue, wf.luma] {
                XCTAssertEqual(ch[wf.index(column: c, level: expectedLevel)], 10, "column \(c)")
            }
        }
        XCTAssertEqual(wf.red.reduce(0, +), 640)
    }

    func testWaveformLevelIsProportionalToValue() {
        let img = ImageBuffer(width: 1, height: 1) { _, _ in (0.5, 0.25, 0.75) }
        let wf = ScopeAnalyzer.analyze(img, configuration: config).waveform
        XCTAssertEqual(wf.red[wf.index(column: 0, level: 512)], 1)   // 0.5 * 1023 = 511.5 -> 512
        XCTAssertEqual(wf.green[wf.index(column: 0, level: 256)], 1) // 255.75 -> 256
        XCTAssertEqual(wf.blue[wf.index(column: 0, level: 767)], 1)  // 767.25 -> 767
    }

    func testOutOfRangeAndNaNAreClamped() {
        let img = ImageBuffer(width: 3, height: 1) { x, _ in
            [(Float(-0.2), Float(1.4), Float.nan), (0, 0, 0), (1, 1, 1)][x]
        }
        let wf = ScopeAnalyzer.analyze(img, configuration: config).waveform
        XCTAssertEqual(wf.red[wf.index(column: 0, level: 0)], 1)
        XCTAssertEqual(wf.green[wf.index(column: 0, level: wf.levels - 1)], 1)
        XCTAssertEqual(wf.blue[wf.index(column: 0, level: 0)], 1)
    }

    func testColumnsAreBinnedWhenImageIsWiderThanScope() {
        let img = ImageBuffer(width: 256, height: 2) { _, _ in (0.5, 0.5, 0.5) }
        let wf = ScopeAnalyzer.analyze(img, configuration: config).waveform
        XCTAssertEqual(wf.columns, 64)
        XCTAssertEqual(wf.samplesPerColumn, 8)
        XCTAssertEqual(wf.luma[wf.index(column: 10, level: 512)], 8)
    }

    func testNeutralPixelsLandInVectorscopeCentre() {
        let img = ImageBuffer(width: 4, height: 4) { _, _ in (0.4, 0.4, 0.4) }
        let vs = ScopeAnalyzer.analyze(img, configuration: config).vectorscope
        let c = vs.size / 2
        XCTAssertEqual(vs.density[c * vs.size + c], 16)
    }

    func testPrimariesLandOnTheirTargets() {
        for target in VectorTarget.primariesAndSecondaries {
            let img = ImageBuffer(width: 1, height: 1) { _, _ in (target.r * 0.75, target.g * 0.75, target.b * 0.75) }
            let vs = ScopeAnalyzer.analyze(img, configuration: config).vectorscope
            let chroma = target.chroma(amplitude: 0.75)
            let pos = vs.gridPosition(cb: chroma.cb, cr: chroma.cr)
            let bin = Int(pos.y) * vs.size + Int(pos.x)
            XCTAssertEqual(vs.density[bin], 1, "target \(target.label) not at expected bin")
        }
    }

    func testRedIsUpperLeftOfCentre() {
        // Convention check: +Cr is up, -Cb is left, so red plots up and slightly left.
        let img = ImageBuffer(width: 1, height: 1) { _, _ in (1, 0, 0) }
        let vs = ScopeAnalyzer.analyze(img, configuration: config).vectorscope
        let idx = vs.density.firstIndex(of: 1)!
        let x = idx % vs.size, y = idx / vs.size
        XCTAssertLessThan(x, vs.size / 2)
        XCTAssertLessThan(y, vs.size / 2)
    }
}

final class RendererTests: XCTestCase {
    func testEmptyBinsStayBlackAndDenseBinsAreBright() {
        let img = ImageBuffer(width: 32, height: 32) { _, _ in (1, 1, 1) }
        var config = ScopeAnalyzerConfiguration()
        config.waveformLevels = 256
        let a = ScopeAnalyzer.analyze(img, configuration: config)
        let raster = ScopeRenderer.renderWaveform(a.waveform, mode: .rgbOverlay, style: .init())
        XCTAssertEqual(raster.width, 32)
        XCTAssertEqual(raster.height, 256)
        // Top row (white) bright and close to neutral, bottom row black.
        let top = Array(raster.bytes[0..<4])
        XCTAssertEqual(top[0], 255); XCTAssertEqual(top[1], 255); XCTAssertEqual(top[2], 255)
        let bottomStart = (255 * 32) * 4
        XCTAssertEqual(Array(raster.bytes[bottomStart..<(bottomStart + 3)]), [0, 0, 0])
        XCTAssertNotNil(raster.makeCGImage())
    }

    func testParadeIsThreeTimesWider() {
        let img = ImageBuffer(width: 16, height: 4) { _, _ in (1, 0, 0) }
        let a = ScopeAnalyzer.analyze(img)
        let raster = ScopeRenderer.renderWaveform(a.waveform, mode: .rgbParade, style: .init())
        XCTAssertEqual(raster.width, 48)
        // Red channel at top of the first third; green/blue thirds empty at top.
        XCTAssertGreaterThan(raster.bytes[0], 200)
        XCTAssertEqual(raster.bytes[16 * 4], 0)
        XCTAssertEqual(raster.bytes[32 * 4 + 2], 0)
    }
}

final class DecoderTests: XCTestCase {
    func testDecodesJPEGAndResamples() throws {
        // Encode a 400x200 mid-grey sRGB JPEG and make sure it round-trips near 0.5.
        let w = 400, h = 200
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.5, 0.5, 0.5, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let buffer = try ImageDecoder.decode(data: data as Data, maxDimension: 100)
        XCTAssertEqual(buffer.width, 100)
        XCTAssertEqual(buffer.height, 50)
        let mid = (25 * 100 + 50) * 4
        XCTAssertEqual(buffer.pixels[mid], 0.5, accuracy: 0.01)
        XCTAssertEqual(buffer.pixels[mid + 3], 1, accuracy: 1e-4)
    }

    func testGarbageDataThrows() {
        XCTAssertThrowsError(try ImageDecoder.decode(data: Data([1, 2, 3]), maxDimension: 64))
    }

    func testFittedSizeNeverUpscales() {
        XCTAssertEqual(ImageDecoder.fittedSize(width: 50, height: 20, maxDimension: 100).0, 50)
        let s = ImageDecoder.fittedSize(width: 3000, height: 2000, maxDimension: 1024)
        XCTAssertEqual(s.0, 1024); XCTAssertEqual(s.1, 683)
    }
}

final class SessionProtocolTests: XCTestCase {
    // Mirrors exactly what SessionFiles.lua emits (key order and number formatting).
    let sample = """
    {"protocol":1,"pluginVersion":"1.0.0","heartbeat":784249200.25,"enabled":true,"quit":false,\
    "module":"develop","photo":{"id":42,"name":"DSC_0001.NEF"},\
    "frame":{"seq":7,"file":"frame-7.jpg","photoId":42}}
    """

    func testDecodesPluginState() throws {
        let s = try PluginState.decode(Data(sample.utf8))
        XCTAssertEqual(s.protocol, 1)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.isInDevelop)
        XCTAssertEqual(s.photo?.name, "DSC_0001.NEF")
        XCTAssertEqual(s.frame?.seq, 7)
        XCTAssertEqual(s.frame?.photoId, 42)
        XCTAssertTrue(s.isFresh(now: 784249203))
        XCTAssertFalse(s.isFresh(now: 784249300))
    }

    func testOptionalFieldsMayBeAbsent() throws {
        let s = try PluginState.decode(Data(#"{"protocol":1,"heartbeat":1,"enabled":false}"#.utf8))
        XCTAssertNil(s.frame)
        XCTAssertNil(s.photo)
        XCTAssertFalse(s.isInDevelop)
    }

    func testFrameFileNameValidation() {
        XCTAssertTrue(PluginState.isSafeFrameFileName("frame-12.jpg"))
        XCTAssertFalse(PluginState.isSafeFrameFileName("../etc/passwd.jpg"))
        XCTAssertFalse(PluginState.isSafeFrameFileName(".hidden.jpg"))
        XCTAssertFalse(PluginState.isSafeFrameFileName("frame-1.png"))
    }
}

final class GraticuleTests: XCTestCase {
    func testAll100PercentTargetsFitInsideDefaultScale() {
        for t in VectorTarget.primariesAndSecondaries {
            let c = t.chroma(amplitude: 1)
            let magnitude = (c.cb * c.cb + c.cr * c.cr).squareRoot()
            XCTAssertLessThan(magnitude, ScopeAnalyzerConfiguration.defaultChromaAtEdge * 0.9, t.label)
        }
    }
}

final class RegionTests: XCTestCase {
    func testSpanningNormalisesAndClamps() {
        let r = ScopeRegion.spanning((0.8, 0.9), (-0.2, 0.1))!
        XCTAssertEqual(r.x, 0); XCTAssertEqual(r.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(r.width, 0.8, accuracy: 1e-12); XCTAssertEqual(r.height, 0.8, accuracy: 1e-12)
        XCTAssertNil(ScopeRegion.spanning((0.5, 0.5), (0.502, 0.9)), "sliver must be rejected")
    }

    func testPixelRectStaysInsideImage() {
        let r = ScopeRegion(x: 0.999, y: 0.999, width: 0.01, height: 0.01).pixelRect(width: 100, height: 50)
        XCTAssertEqual(r.x, 99); XCTAssertEqual(r.y, 49); XCTAssertEqual(r.width, 1); XCTAssertEqual(r.height, 1)
        let full = ScopeRegion(x: 0, y: 0, width: 1, height: 1).pixelRect(width: 100, height: 50)
        XCTAssertEqual(full.width, 100); XCTAssertEqual(full.height, 50)
    }

    func testCropSelectsTheRightPixels() {
        // Left half black, right half white; top-right quadrant only must be white.
        let img = ImageBuffer(width: 40, height: 20) { x, y in x >= 20 ? (1, 1, 1) : (0, 0, 0) }
        let crop = img.cropped(to: ScopeRegion(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(crop.width, 20); XCTAssertEqual(crop.height, 10)
        XCTAssertTrue(stride(from: 0, to: crop.pixels.count, by: 4).allSatisfy { crop.pixels[$0] == 1 })
        // Top-down orientation: a top-only marker must survive a top crop.
        let marked = ImageBuffer(width: 10, height: 10) { _, y in y == 0 ? (1, 0, 0) : (0, 0, 0) }
        let top = marked.cropped(to: ScopeRegion(x: 0, y: 0, width: 1, height: 0.1))
        XCTAssertEqual(top.height, 1); XCTAssertEqual(top.pixels[0], 1)
    }

    func testRegionChangesTheScopes() {
        let img = ImageBuffer(width: 40, height: 20) { x, _ in x >= 20 ? (1, 1, 1) : (0, 0, 0) }
        let wf = ScopeAnalyzer.analyze(img.cropped(to: ScopeRegion(x: 0, y: 0, width: 0.5, height: 1))).waveform
        XCTAssertEqual(wf.luma[wf.index(column: 0, level: wf.levels - 1)], 0, "white must not appear in a black-only region")
        XCTAssertEqual(wf.columns, 20)
    }

    func testRotatedJPEGIsDisplayOriented() throws {
        // 40x20 image, left half white, tagged "rotate 90° CW" (orientation 6):
        // displayed it is 20x40 with the white half on top.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let buffer = try ImageDecoder.decode(data: data as Data, maxDimension: 100)
        XCTAssertEqual(buffer.width, 20); XCTAssertEqual(buffer.height, 40)
        XCTAssertGreaterThan(buffer.pixels[(5 * 20 + 10) * 4], 0.9, "top should be white")
        XCTAssertLessThan(buffer.pixels[(35 * 20 + 10) * 4], 0.1, "bottom should be black")
    }
}

final class DitherTests: XCTestCase {
    /// 8-bit gradient: without dither only every ~4th level of 1024 is used.
    private func gradient() -> ImageBuffer {
        ImageBuffer(width: 256, height: 64) { x, _ in
            let v = Float(x) / 255
            return (v, v, v)
        }
    }

    func testDitherFillsCombGaps() {
        var exact = ScopeAnalyzerConfiguration(); exact.sourceQuantizationStep = 0
        let comb = ScopeAnalyzer.analyze(gradient(), configuration: exact).waveform
        let dithered = ScopeAnalyzer.analyze(gradient()).waveform
        func usedLevels(_ wf: WaveformData) -> Int {
            (0..<wf.levels).filter { l in (0..<wf.columns).contains { wf.luma[wf.index(column: $0, level: l)] > 0 } }.count
        }
        XCTAssertLessThanOrEqual(usedLevels(comb), 256)
        XCTAssertGreaterThan(usedLevels(dithered), 900, "dither should populate nearly every level")
    }

    func testDitherStaysWithinOneSourceStep() {
        // Every sample of value v must land within ±0.5/255 of v (≈ ±2 levels of 1023).
        let img = ImageBuffer(width: 64, height: 64) { _, _ in (0.5, 0.5, 0.5) }
        let wf = ScopeAnalyzer.analyze(img).waveform
        let centre = Int((0.5 * 1023).rounded())
        for l in 0..<wf.levels where wf.luma[wf.index(column: 0, level: l)] > 0 {
            XCTAssertLessThanOrEqual(abs(l - centre), 3, "level \(l) too far from \(centre)")
        }
    }

    func testDitherIsDeterministic() {
        let a = ScopeAnalyzer.analyze(gradient()).waveform.luma
        let b = ScopeAnalyzer.analyze(gradient()).waveform.luma
        XCTAssertEqual(a, b)
    }
}
