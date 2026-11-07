import AppKit
import ScopesCore

enum ScopePalette {
    static let background = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.08, alpha: 1)
    static let plotBackground = NSColor.black
    static let graticule = NSColor(white: 1, alpha: 0.16)
    static let graticuleStrong = NSColor(white: 1, alpha: 0.30)
    static let label = NSColor(white: 1, alpha: 0.45)
    static let message = NSColor(white: 1, alpha: 0.55)
    static let skinTone = NSColor(srgbRed: 1, green: 0.78, blue: 0.55, alpha: 0.45)
    static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
}

/// Common drawing for both scopes: dark background, optional centred message.
class ScopeBaseView: NSView {
    var message: String? { didSet { needsDisplay = true } }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func drawMessage(in rect: NSRect) {
        guard let message else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ScopePalette.message, .paragraphStyle: style,
        ]
        let size = (message as NSString).boundingRect(with: NSSize(width: rect.width - 20, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: attrs).size
        let r = NSRect(x: rect.minX + 10, y: rect.midY - size.height / 2, width: rect.width - 20, height: size.height)
        (message as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    func drawLabel(_ text: String, at point: NSPoint, alignment: NSTextAlignment, color: NSColor = ScopePalette.label) {
        let attrs: [NSAttributedString.Key: Any] = [.font: ScopePalette.labelFont, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = NSPoint(x: point.x, y: point.y - size.height / 2)
        switch alignment {
        case .right: origin.x -= size.width
        case .center: origin.x -= size.width / 2
        default: break
        }
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}

/// Waveform with a 10-bit (0–1023) graticule, as in Resolve.
final class WaveformView: ScopeBaseView {
    var trace: CGImage? { didSet { needsDisplay = true } }
    var mode: WaveformMode = .rgbParade { didSet { needsDisplay = true } }

    private let leftMargin: CGFloat = 34
    private let inset: CGFloat = 8

    var plotRect: NSRect {
        bounds.insetBy(dx: inset, dy: inset).divided(atDistance: leftMargin - inset, from: .minXEdge).remainder
    }

    override func draw(_ dirtyRect: NSRect) {
        ScopePalette.background.setFill()
        bounds.fill()
        let plot = plotRect
        guard plot.width > 20, plot.height > 20 else { return }
        ScopePalette.plotBackground.setFill()
        plot.fill()

        if let trace, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            if mode == .rgbParade {
                // Three panes with a small gutter; the raster holds them side by side.
                let gutter: CGFloat = 4
                let paneWidth = (plot.width - 2 * gutter) / 3
                let srcPane = trace.width / 3
                for i in 0..<3 {
                    guard let part = trace.cropping(to: CGRect(x: i * srcPane, y: 0, width: srcPane, height: trace.height)) else { continue }
                    let dst = CGRect(x: plot.minX + CGFloat(i) * (paneWidth + gutter), y: plot.minY, width: paneWidth, height: plot.height)
                    ctx.setBlendMode(.normal)
                    ctx.draw(part, in: dst)
                }
            } else {
                ctx.draw(trace, in: plot)
            }
            ctx.restoreGState()
        }

        // Graticule: every 128 code values, labelled on the left.
        let path = NSBezierPath()
        path.lineWidth = 1
        for code in stride(from: 0, through: 1024, by: 128) {
            let value = min(code, 1023)
            let y = (plot.minY + CGFloat(value) / 1023 * plot.height).rounded() + 0.5
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            drawLabel("\(value)", at: NSPoint(x: plot.minX - 5, y: y), alignment: .right)
        }
        ScopePalette.graticule.setStroke()
        path.stroke()

        drawMessage(in: plot)
    }
}

/// Vectorscope with colour-bar targets (75% boxes, 100% labels) and the skin tone line.
final class VectorscopeView: ScopeBaseView {
    var trace: CGImage? { didSet { needsDisplay = true } }
    var chromaAtEdge: Float = ScopeAnalyzerConfiguration.defaultChromaAtEdge { didSet { needsDisplay = true } }
    var showSkinToneLine = true { didSet { needsDisplay = true } }

    private let inset: CGFloat = 10

    var plotRect: NSRect {
        let available = bounds.insetBy(dx: inset, dy: inset)
        let side = max(0, min(available.width, available.height)).rounded(.down)
        return NSRect(x: (available.midX - side / 2).rounded(), y: (available.midY - side / 2).rounded(), width: side, height: side)
    }

    private func point(cb: Float, cr: Float, in plot: NSRect) -> NSPoint {
        let half = plot.width / 2
        return NSPoint(x: plot.midX + CGFloat(cb / chromaAtEdge) * half,
                       y: plot.midY + CGFloat(cr / chromaAtEdge) * half)
    }

    override func draw(_ dirtyRect: NSRect) {
        ScopePalette.background.setFill()
        bounds.fill()
        let plot = plotRect
        guard plot.width > 40 else { return }

        let circle = NSBezierPath(ovalIn: plot)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        ScopePalette.plotBackground.setFill()
        plot.fill()
        if let trace, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .high
            ctx.draw(trace, in: plot)
        }

        // Crosshair and inner rings.
        let grid = NSBezierPath()
        grid.lineWidth = 1
        grid.move(to: NSPoint(x: plot.minX, y: plot.midY)); grid.line(to: NSPoint(x: plot.maxX, y: plot.midY))
        grid.move(to: NSPoint(x: plot.midX, y: plot.minY)); grid.line(to: NSPoint(x: plot.midX, y: plot.maxY))
        ScopePalette.graticule.setStroke()
        grid.stroke()

        if showSkinToneLine {
            let angle = CGFloat(Rec709.skinToneAngleDegrees) * .pi / 180
            let skin = NSBezierPath()
            skin.lineWidth = 1
            skin.move(to: NSPoint(x: plot.midX, y: plot.midY))
            skin.line(to: NSPoint(x: plot.midX + cos(angle) * plot.width / 2, y: plot.midY + sin(angle) * plot.height / 2))
            ScopePalette.skinTone.setStroke()
            skin.stroke()
        }

        // Targets: small boxes at 75% bars, labels just outside 100% bars.
        let box: CGFloat = max(6, plot.width * 0.022)
        let boxes = NSBezierPath()
        boxes.lineWidth = 1
        for target in VectorTarget.primariesAndSecondaries {
            let c75 = target.chroma(amplitude: 0.75)
            let p75 = point(cb: c75.cb, cr: c75.cr, in: plot)
            boxes.appendRect(NSRect(x: p75.x - box / 2, y: p75.y - box / 2, width: box, height: box))

            let c100 = target.chroma(amplitude: 1)
            let p100 = point(cb: c100.cb, cr: c100.cr, in: plot)
            let tick = box * 0.35
            boxes.move(to: NSPoint(x: p100.x - tick, y: p100.y)); boxes.line(to: NSPoint(x: p100.x + tick, y: p100.y))
            boxes.move(to: NSPoint(x: p100.x, y: p100.y - tick)); boxes.line(to: NSPoint(x: p100.x, y: p100.y + tick))

            // Label slightly further out along the same direction.
            let dx = p100.x - plot.midX, dy = p100.y - plot.midY
            let len = max(1, hypot(dx, dy))
            let labelPoint = NSPoint(x: p100.x + dx / len * 11, y: p100.y + dy / len * 11)
            if plot.insetBy(dx: 6, dy: 6).contains(labelPoint) {
                drawLabel(target.label, at: labelPoint, alignment: .center, color: ScopePalette.graticuleStrong)
            }
        }
        ScopePalette.graticuleStrong.setStroke()
        boxes.stroke()
        NSGraphicsContext.restoreGraphicsState()

        ScopePalette.graticuleStrong.setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let zoom = ScopeAnalyzerConfiguration.defaultChromaAtEdge / chromaAtEdge
        if zoom > 1.01 {
            drawLabel(String(format: "%.0f×", zoom), at: NSPoint(x: plot.maxX - 4, y: plot.maxY - 6), alignment: .right)
        }
        drawMessage(in: plot)
    }
}
