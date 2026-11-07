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
    /// Short tag drawn in the top-right corner, e.g. "REGION" while a region is active.
    var badge: String? { didSet { if badge != oldValue { needsDisplay = true } } }

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

    func drawBadge(in rect: NSRect) {
        guard let badge else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.black,
        ]
        let size = (badge as NSString).size(withAttributes: attrs)
        let box = NSRect(x: rect.maxX - size.width - 12, y: rect.maxY - size.height - 8,
                         width: size.width + 8, height: size.height + 2)
        NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (badge as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: attrs)
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

        drawBadge(in: plot)
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
        drawBadge(in: bounds)
        drawMessage(in: plot)
    }
}

/// Thumbnail of the photo on which the user drags out the region the scopes measure.
///
/// Drag to select. Click on the image outside the selection, double-click, or
/// right-click › Measure Whole Image to go back to the whole image.
/// Updates are reported live while dragging; the processor drops stale work.
final class NavigatorView: ScopeBaseView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var region: ScopeRegion? { didSet { if region != oldValue { needsDisplay = true } } }
    var onRegionChanged: ((ScopeRegion?) -> Void)?

    private var dragStart: (x: Double, y: Double)?
    /// True once the current gesture has produced a region (i.e. it is a drag, not a click).
    private var gestureSelected = false
    private let inset: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let menu = NSMenu()
        menu.addItem(withTitle: "Measure Whole Image", action: #selector(resetRegion(_:)), keyEquivalent: "").target = self
        self.menu = menu
        toolTip = "Drag to choose the area the scopes measure. Click outside the selection to measure the whole image."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The panel never becomes key; react to the very first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the image is drawn: aspect-fit inside the view.
    var imageRect: NSRect {
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard let image, image.width > 0, image.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }

    /// View point -> normalised image coordinates (top-left origin), unclamped.
    func normalizedPoint(_ p: NSPoint) -> (x: Double, y: Double) {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        return (Double((p.x - r.minX) / r.width), Double((r.maxY - p.y) / r.height))
    }

    /// Normalised region -> view rectangle.
    func viewRect(for region: ScopeRegion) -> NSRect {
        let r = imageRect
        return NSRect(x: r.minX + CGFloat(region.x) * r.width,
                      y: r.maxY - CGFloat(region.y + region.height) * r.height,
                      width: CGFloat(region.width) * r.width,
                      height: CGFloat(region.height) * r.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        if event.clickCount == 2 {
            dragStart = nil
            setRegion(nil)
            return
        }
        dragStart = normalizedPoint(convert(event.locationInWindow, from: nil))
        gestureSelected = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = normalizedPoint(convert(event.locationInWindow, from: nil))
        // A drag that is still too small keeps the previous region on screen.
        if let r = ScopeRegion.spanning(start, current) {
            gestureSelected = true
            setRegion(r)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; gestureSelected = false }
        guard dragStart != nil, !gestureSelected, let region else { return }
        // A click (no drag) on the image but outside the selection clears it. Clicks
        // inside the selection, or in the margin around the image, change nothing.
        let p = convert(event.locationInWindow, from: nil)
        if imageRect.contains(p) && !viewRect(for: region).contains(p) {
            setRegion(nil)
        }
    }

    @objc func resetRegion(_ sender: Any?) { setRegion(nil) }

    private func setRegion(_ r: ScopeRegion?) {
        guard r != region else { return }
        region = r
        onRegionChanged?(r)
    }

    override func draw(_ dirtyRect: NSRect) {
        ScopePalette.background.setFill()
        bounds.fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else {
            drawMessage(in: bounds)
            return
        }
        let r = imageRect
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)

        if let region {
            let sel = viewRect(for: region)
            // Dim everything outside the selection.
            let shade = NSBezierPath(rect: r)
            shade.appendRect(sel)
            shade.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.6).setFill()
            shade.fill()
            let outline = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            NSColor.white.setStroke()
            outline.stroke()
        }
        NSColor(white: 1, alpha: 0.2).setStroke()
        NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}
