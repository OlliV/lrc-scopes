import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LRCScopes
import ScopesCore

/// In-process UI tests: the real panel controller, its controls and views.
final class PanelTests: XCTestCase {
    private var controller: ScopesPanelController!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        controller = ScopesPanelController(settings: ScopeSettings())
        setContentSize(NSSize(width: 900, height: 380))
    }

    override func tearDown() {
        controller.window?.orderOut(nil)
        controller = nil
        super.tearDown()
    }

    private var window: NSWindow { controller.window! }

    private func setContentSize(_ size: NSSize) {
        window.setContentSize(size)
        layout()
    }

    private func layout() {
        window.contentView?.needsLayout = true
        window.layoutIfNeeded()
    }

    private func select(_ control: NSSegmentedControl, _ segment: Int) {
        control.selectedSegment = segment
        controller.controlChanged(control)
        layout()
    }

    // MARK: Layout switching

    func testBothRestoresBothScopesAfterSwitching() {
        let both = ScopeLayout.allCases.firstIndex(of: .both)!
        let waveformOnly = ScopeLayout.allCases.firstIndex(of: .waveform)!
        let vectorscopeOnly = ScopeLayout.allCases.firstIndex(of: .vectorscope)!

        for other in [waveformOnly, vectorscopeOnly] {
            select(controller.layoutControl, other)
            select(controller.layoutControl, both)
            let wf = controller.waveformView, vs = controller.vectorscopeView
            XCTAssertFalse(wf.isHidden, "waveform hidden after Both")
            XCTAssertFalse(vs.isHidden, "vectorscope hidden after Both")
            XCTAssertGreaterThan(wf.frame.width, 100)
            XCTAssertGreaterThan(vs.frame.width, 100)
            XCTAssertFalse(wf.frame.intersects(vs.frame), "scopes overlap")
            XCTAssertEqual(controller.settings.layout, .both)
        }
    }

    func testSingleScopeLayoutsFillTheWidth() {
        select(controller.layoutControl, ScopeLayout.allCases.firstIndex(of: .waveform)!)
        XCTAssertTrue(controller.vectorscopeView.isHidden)
        XCTAssertEqual(controller.waveformView.frame.width, 900, accuracy: 0.5)

        select(controller.layoutControl, ScopeLayout.allCases.firstIndex(of: .vectorscope)!)
        XCTAssertTrue(controller.waveformView.isHidden)
        XCTAssertEqual(controller.vectorscopeView.frame.width, 900, accuracy: 0.5)
    }

    // MARK: Window sizing

    func testContentNeverResizesTheWindow() {
        let sizes = [NSSize(width: 420, height: 220), NSSize(width: 1800, height: 300),
                     NSSize(width: 480, height: 1000), NSSize(width: 900, height: 380)]
        controller.setStatus(String(repeating: "VeryLongFileName_", count: 20) + ".3FR")
        for size in sizes {
            for layout in ScopeLayout.allCases.indices {
                select(controller.layoutControl, layout)
                setContentSize(size)
                let actual = window.contentRect(forFrameRect: window.frame).size
                XCTAssertEqual(actual.width, size.width, accuracy: 0.5, "width changed at \(size), layout \(layout)")
                XCTAssertEqual(actual.height, size.height, accuracy: 0.5, "height changed at \(size), layout \(layout)")
                // Everything stays inside the window.
                let bounds = window.contentView!.bounds
                for v in [controller.waveformView, controller.vectorscopeView] where !v.isHidden {
                    XCTAssertTrue(bounds.contains(v.frame), "\(v) outside window at \(size)")
                }
            }
        }
    }

    func testPanelHasNoCloseButtonUnderThePlugin() throws {
        var closed = 0
        controller.onUserClosed = { closed += 1 }
        let window = try XCTUnwrap(controller.window)
        controller.show(true)
        XCTAssertFalse(window.styleMask.contains(.closable))
        XCTAssertNil(window.standardWindowButton(.closeButton).flatMap { $0.isEnabled ? $0 : nil })
        window.performClose(nil) // also what Esc and Cmd-W end up doing
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(closed, 0)
    }

    func testHandStartedHelperCanBeClosed() throws {
        let c = ScopesPanelController(settings: ScopeSettings(), closable: true)
        XCTAssertTrue(try XCTUnwrap(c.window).styleMask.contains(.closable))
    }

    func testUpdatingSpinnerDoesNotMoveTheToolbar() throws {
        let window = try XCTUnwrap(controller.window)
        controller.show(true)
        window.layoutIfNeeded()
        XCTAssertTrue(controller.updatingIndicator.superview != nil, "spinner is in the toolbar")
        let statusFrame = controller.statusLabel.frame
        let windowFrame = window.frame
        controller.setUpdating(true)
        window.layoutIfNeeded()
        XCTAssertTrue(controller.isShowingUpdating)
        XCTAssertEqual(controller.statusLabel.frame, statusFrame, "showing the spinner doesn't shift controls")
        XCTAssertEqual(window.frame, windowFrame)
        controller.setUpdating(false)
        XCTAssertFalse(controller.isShowingUpdating)
    }

    func testFrameMath() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 330)
        let f = ScopesContentView.frames(in: bounds, toolbarHeight: 30, layout: .both)
        XCTAssertEqual(f.vectorscope!.width, 300)  // square: limited by height
        XCTAssertEqual(f.waveform!.width, 699)     // rest minus separator
        XCTAssertEqual(f.toolbar.minY, 300)
        // Tall, narrow: vectorscope capped at half the width.
        let tall = ScopesContentView.frames(in: NSRect(x: 0, y: 0, width: 400, height: 900), toolbarHeight: 30, layout: .both)
        XCTAssertEqual(tall.vectorscope!.width, 200)
        // Degenerate sizes never produce negative frames.
        let tiny = ScopesContentView.frames(in: NSRect(x: 0, y: 0, width: 10, height: 10), toolbarHeight: 30, layout: .both)
        XCTAssertGreaterThanOrEqual(tiny.waveform!.width, 0)
        XCTAssertGreaterThanOrEqual(tiny.waveform!.height, 0)
    }

    func testSavedFrameIsClampedToScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let huge = NSRect(x: -500, y: -500, width: 9000, height: 6000)
        let c = ScopesPanelController.clamp(huge, to: visible, minimum: NSSize(width: 420, height: 250))
        XCTAssertEqual(c, visible)
        let tiny = ScopesPanelController.clamp(NSRect(x: 100, y: 100, width: 10, height: 10), to: visible, minimum: NSSize(width: 420, height: 250))
        XCTAssertEqual(tiny.size, NSSize(width: 420, height: 250))
    }

    // MARK: Intensity slider

    func testDoubleClickResetsIntensity() throws {
        let slider = controller.gainSlider
        slider.doubleValue = 3.5
        controller.controlChanged(slider)
        XCTAssertEqual(controller.settings.gain, 3.5, accuracy: 1e-4)

        var notified: ScopeSettings?
        controller.onSettingsChanged = { notified = $0 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 2, pressure: 1))
        slider.mouseDown(with: event)
        XCTAssertEqual(controller.settings.gain, ScopeSettings.defaultGain, accuracy: 1e-4)
        XCTAssertEqual(notified?.gain ?? -1, ScopeSettings.defaultGain, accuracy: 1e-4)
    }

    // MARK: Vectorscope zoom, end to end through the processor

    func testZoomButtonMagnifiesVectorscope() throws {
        let processor = FrameProcessor()
        var outputs: [FrameProcessor.Output] = []
        var expectation = self.expectation(description: "1x output")
        processor.onOutput = { output in
            outputs.append(output)
            self.controller.display(output)
            expectation.fulfill()
        }
        controller.onSettingsChanged = { processor.submit(jpeg: nil, settings: $0) }

        processor.submit(jpeg: try Self.makeJPEG(), settings: controller.settings)
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(controller.vectorscopeView.chromaAtEdge, ScopeAnalyzerConfiguration.defaultChromaAtEdge, accuracy: 1e-6)

        expectation = self.expectation(description: "2x output")
        select(controller.zoomControl, 1)
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(controller.settings.vectorscopeZoom, 2)
        XCTAssertEqual(controller.vectorscopeView.chromaAtEdge, ScopeAnalyzerConfiguration.defaultChromaAtEdge / 2, accuracy: 1e-6)
        let a = try XCTUnwrap(outputs.first?.vectorscope), b = try XCTUnwrap(outputs.last?.vectorscope)
        XCTAssertNotEqual(Self.pixels(a), Self.pixels(b), "2x trace identical to 1x")
    }

    private static func pixels(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    /// A low-saturation gradient, typical of real photos (lives near the centre).
    private static func makeJPEG() throws -> Data {
        let w = 256, h = 64
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<w {
            let t = CGFloat(x) / CGFloat(w - 1)
            ctx.setFillColor(CGColor(colorSpace: cs, components: [0.5 + 0.15 * t, 0.45, 0.5 - 0.15 * t, 1])!)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }
}

/// Region selection: the navigator, its interaction, and its effect on the scopes.
final class RegionPanelTests: XCTestCase {
    private var controller: ScopesPanelController!
    private var window: NSWindow { controller.window! }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        var s = ScopeSettings()
        s.showsRegionSelector = false
        controller = ScopesPanelController(settings: s)
        window.setContentSize(NSSize(width: 1000, height: 380))
        layout()
    }

    private func layout() {
        window.contentView?.needsLayout = true
        window.layoutIfNeeded()
    }

    private func toggleRegion() {
        controller.regionButton.performClick(nil)
        layout()
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, clicks: Int = 1) -> NSEvent {
        let inWindow = controller.navigatorView.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: 1)!
    }

    private func setImage(width: Int, height: Int) {
        let raster = RGBA8Raster(width: width, height: height)
        controller.navigatorView.image = raster.makeCGImage()
    }

    func testRegionButtonShowsNavigatorWithoutOverlap() {
        XCTAssertTrue(controller.navigatorView.isHidden)
        toggleRegion()
        let nav = controller.navigatorView, wf = controller.waveformView, vs = controller.vectorscopeView
        XCTAssertFalse(nav.isHidden)
        XCTAssertGreaterThan(nav.frame.width, 100)
        XCTAssertFalse(nav.frame.intersects(wf.frame))
        XCTAssertFalse(nav.frame.intersects(vs.frame))
        XCTAssertFalse(wf.frame.intersects(vs.frame))
        XCTAssertTrue(controller.settings.showsRegionSelector)
    }

    func testDragSelectsRegionAndDoubleClickResets() throws {
        toggleRegion()
        setImage(width: 300, height: 200)
        let nav = controller.navigatorView
        let r = nav.imageRect
        // Drag from 25%/25% to 75%/50% of the image (top-left origin).
        let start = NSPoint(x: r.minX + r.width * 0.25, y: r.maxY - r.height * 0.25)
        let end = NSPoint(x: r.minX + r.width * 0.75, y: r.maxY - r.height * 0.5)
        nav.mouseDown(with: mouse(.leftMouseDown, at: start))
        nav.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        nav.mouseUp(with: mouse(.leftMouseUp, at: end))

        let region = try XCTUnwrap(controller.settings.region)
        XCTAssertEqual(region.x, 0.25, accuracy: 0.01)
        XCTAssertEqual(region.y, 0.25, accuracy: 0.01)
        XCTAssertEqual(region.width, 0.5, accuracy: 0.01)
        XCTAssertEqual(region.height, 0.25, accuracy: 0.01)

        func click(_ p: NSPoint) {
            nav.mouseDown(with: mouse(.leftMouseDown, at: p))
            nav.mouseUp(with: mouse(.leftMouseUp, at: p))
        }
        let selection = nav.viewRect(for: region)

        // Click inside the selection: kept.
        click(NSPoint(x: selection.midX, y: selection.midY))
        XCTAssertEqual(controller.settings.region, region)

        // Click in the margin around the image (inside the view): kept.
        click(NSPoint(x: nav.bounds.minX + 2, y: nav.bounds.minY + 2))
        XCTAssertFalse(r.contains(NSPoint(x: nav.bounds.minX + 2, y: nav.bounds.minY + 2)), "test point must be in the margin")
        XCTAssertEqual(controller.settings.region, region)

        // Click on the image outside the selection: whole image.
        click(NSPoint(x: r.minX + r.width * 0.1, y: r.maxY - r.height * 0.9))
        XCTAssertNil(controller.settings.region)
    }

    func testDragStartingOutsideSelectionReplacesItInsteadOfResetting() throws {
        toggleRegion()
        setImage(width: 300, height: 200)
        let nav = controller.navigatorView
        let r = nav.imageRect
        func drag(_ a: (Double, Double), _ b: (Double, Double)) {
            let pa = NSPoint(x: r.minX + r.width * a.0, y: r.maxY - r.height * a.1)
            let pb = NSPoint(x: r.minX + r.width * b.0, y: r.maxY - r.height * b.1)
            nav.mouseDown(with: mouse(.leftMouseDown, at: pa))
            nav.mouseDragged(with: mouse(.leftMouseDragged, at: pb))
            nav.mouseUp(with: mouse(.leftMouseUp, at: pb))
        }
        drag((0.1, 0.1), (0.3, 0.3))
        drag((0.6, 0.6), (0.9, 0.9)) // starts and ends outside the first selection
        let region = try XCTUnwrap(controller.settings.region)
        XCTAssertEqual(region.x, 0.6, accuracy: 0.01)
        XCTAssertEqual(region.width, 0.3, accuracy: 0.01)
    }

    func testDoubleClickStillResets() {
        toggleRegion()
        setImage(width: 300, height: 200)
        controller.navigatorView.onRegionChanged?(ScopeRegion(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        controller.navigatorView.region = controller.settings.region
        let sel = controller.navigatorView.viewRect(for: controller.settings.region!)
        controller.navigatorView.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: sel.midX, y: sel.midY), clicks: 2))
        XCTAssertNil(controller.settings.region)
    }

    func testHidingNavigatorMeasuresWholeImageAgain() {
        toggleRegion()
        controller.navigatorView.region = nil
        var s = controller.settings
        s.region = ScopeRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        controller.navigatorView.onRegionChanged?(s.region)
        XCTAssertNotNil(controller.settings.region)
        toggleRegion()
        XCTAssertNil(controller.settings.region)
        XCTAssertTrue(controller.navigatorView.isHidden)
    }

    func testResetRegion() {
        toggleRegion()
        controller.navigatorView.onRegionChanged?(ScopeRegion(x: 0, y: 0, width: 0.5, height: 0.5))
        controller.resetRegion()
        XCTAssertNil(controller.settings.region)
        XCTAssertTrue(controller.settings.showsRegionSelector, "reset keeps the navigator open")
    }

    func testRegionIsAppliedByProcessorAndBadged() throws {
        // Left half black, right half white.
        let w = 200, h = 100
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let processor = FrameProcessor()
        var outputs: [FrameProcessor.Output] = []
        // Fulfil only on the first output that satisfies the current predicate;
        // other settings changes (e.g. pressing Region) also produce outputs.
        var waiting: (exp: XCTestExpectation, matches: (FrameProcessor.Output) -> Bool)?
        processor.onOutput = { output in
            outputs.append(output)
            self.controller.display(output)
            if let w = waiting, w.matches(output) { waiting = nil; w.exp.fulfill() }
        }
        controller.onSettingsChanged = { processor.submit(jpeg: nil, settings: $0) }

        let whole = expectation(description: "whole")
        waiting = (whole, { $0.region == nil })
        processor.submit(jpeg: data as Data, settings: controller.settings)
        wait(for: [whole], timeout: 5)
        XCTAssertNil(controller.waveformView.badge)
        XCTAssertNotNil(controller.navigatorView.image)

        toggleRegion()
        let regional = expectation(description: "region")
        waiting = (regional, { $0.region != nil })
        controller.navigatorView.onRegionChanged?(ScopeRegion(x: 0, y: 0, width: 0.45, height: 1))
        wait(for: [regional], timeout: 5)
        XCTAssertEqual(controller.waveformView.badge, "REGION")
        XCTAssertEqual(controller.vectorscopeView.badge, "REGION")
        // Waveform of the black-only region has nothing near the top.
        let wfImage = try XCTUnwrap(outputs.last?.waveform)
        let bytes = [UInt8](wfImage.dataProvider!.data! as Data)
        let topRows = bytes[0..<(wfImage.width * 4 * 50)]
        XCTAssertEqual(topRows.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).max(), 0,
                       "white pixels outside the region leaked into the waveform")
    }

    func testFrameMathWithNavigator() {
        let f = ScopesContentView.frames(in: NSRect(x: 0, y: 0, width: 1200, height: 330), toolbarHeight: 30,
                                         layout: .both, showsNavigator: true)
        let nav = try! XCTUnwrap(f.navigator)
        XCTAssertEqual(nav.width, 260) // capped
        XCTAssertEqual(nav.minX, 0)
        XCTAssertGreaterThan(f.waveform!.minX, nav.maxX)
        XCTAssertEqual(f.vectorscope!.maxX, 1200)
    }
}
