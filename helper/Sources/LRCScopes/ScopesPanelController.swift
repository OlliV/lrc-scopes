import AppKit
import ScopesCore

/// Lays out the toolbar and scopes with explicit frames.
///
/// Deliberately not Auto Layout: constraints between the scopes (e.g. "vectorscope is
/// square") can outrank the window's own size priority and make AppKit resize the
/// window to satisfy them. Here the window size is always the user's; the content
/// adapts to it and never pushes back.
final class ScopesContentView: NSView {
    let toolbar: NSView
    let waveformView: WaveformView
    let vectorscopeView: VectorscopeView
    let navigatorView: NavigatorView
    var layoutMode: ScopeLayout = .both {
        didSet { if layoutMode != oldValue { needsLayout = true } }
    }
    var showsNavigator = false {
        didSet { if showsNavigator != oldValue { needsLayout = true } }
    }

    static let separator: CGFloat = 1
    /// The vectorscope never takes more than this share of the width in "Both".
    static let maxVectorscopeShare: CGFloat = 0.5
    /// The navigator takes at most this share of the width, and never more than
    /// `maxNavigatorWidth` points.
    static let navigatorShare: CGFloat = 0.25
    static let maxNavigatorWidth: CGFloat = 260

    init(toolbar: NSView, waveformView: WaveformView, vectorscopeView: VectorscopeView, navigatorView: NavigatorView) {
        self.toolbar = toolbar
        self.waveformView = waveformView
        self.vectorscopeView = vectorscopeView
        self.navigatorView = navigatorView
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        for v in [toolbar, navigatorView, waveformView, vectorscopeView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = []
            addSubview(v)
        }
        wantsLayer = true
        layer?.backgroundColor = ScopePalette.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    var toolbarHeight: CGFloat { max(28, ceil(toolbar.fittingSize.height)) }

    /// Pure frame computation, also used by tests.
    struct Frames {
        var toolbar: NSRect
        var navigator: NSRect?
        var waveform: NSRect?
        var vectorscope: NSRect?
    }

    static func frames(in bounds: NSRect, toolbarHeight: CGFloat, layout: ScopeLayout, showsNavigator: Bool = false) -> Frames {
        let toolbarRect = NSRect(x: bounds.minX, y: bounds.maxY - toolbarHeight, width: bounds.width, height: toolbarHeight)
        var scopes = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
        var navigator: NSRect?
        if showsNavigator {
            let w = floor(min(maxNavigatorWidth, scopes.width * navigatorShare))
            navigator = NSRect(x: scopes.minX, y: scopes.minY, width: w, height: scopes.height)
            scopes.origin.x += w + separator
            scopes.size.width = max(0, scopes.width - w - separator)
        }
        switch layout {
        case .waveform:
            return Frames(toolbar: toolbarRect, navigator: navigator, waveform: scopes, vectorscope: nil)
        case .vectorscope:
            return Frames(toolbar: toolbarRect, navigator: navigator, waveform: nil, vectorscope: scopes)
        case .both:
            let side = floor(min(scopes.height, scopes.width * maxVectorscopeShare))
            let vs = NSRect(x: scopes.maxX - side, y: scopes.minY, width: side, height: scopes.height)
            let wf = NSRect(x: scopes.minX, y: scopes.minY, width: max(0, scopes.width - side - separator), height: scopes.height)
            return Frames(toolbar: toolbarRect, navigator: navigator, waveform: wf, vectorscope: vs)
        }
    }

    override func layout() {
        super.layout()
        let f = Self.frames(in: bounds, toolbarHeight: toolbarHeight, layout: layoutMode, showsNavigator: showsNavigator)
        toolbar.frame = f.toolbar
        navigatorView.isHidden = f.navigator == nil
        if let r = f.navigator { navigatorView.frame = r }
        waveformView.isHidden = f.waveform == nil
        vectorscopeView.isHidden = f.vectorscope == nil
        if let r = f.waveform { waveformView.frame = r }
        if let r = f.vectorscope { vectorscopeView.frame = r }
    }
}

/// A slider that returns to its default value on double-click.
final class ResettableSlider: NSSlider {
    var defaultValue: Double = 0

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            doubleValue = defaultValue
            sendAction(action, to: target)
            return
        }
        super.mouseDown(with: event)
    }
}

/// A floating, non-activating HUD panel holding the scopes and their controls.
///
/// Non-activating matters: clicking the scopes must never take keyboard focus away
/// from Lightroom, or Develop shortcuts would stop working.
final class ScopesPanelController: NSWindowController, NSWindowDelegate {
    var onSettingsChanged: ((ScopeSettings) -> Void)?
    var onUserClosed: (() -> Void)?

    static let minimumContentSize = NSSize(width: 420, height: 220)
    static let defaultContentSize = NSSize(width: 880, height: 360)

    private(set) var settings: ScopeSettings
    let waveformView = WaveformView(frame: .zero)
    let vectorscopeView = VectorscopeView(frame: .zero)
    let navigatorView = NavigatorView(frame: .zero)
    private(set) var contentView: ScopesContentView!
    let statusLabel = NSTextField(labelWithString: "")
    /// Spins while the plug-in waits for Lightroom to render the latest edit. Always in
    /// the toolbar (hidden when stopped) so showing it never shifts the other controls.
    let updatingIndicator = NSProgressIndicator()

    let layoutControl = NSSegmentedControl()
    let modeControl = NSSegmentedControl()
    let zoomControl = NSSegmentedControl()
    let colorizeCheckbox = NSButton(checkboxWithTitle: "Color", target: nil, action: nil)
    let skinCheckbox = NSButton(checkboxWithTitle: "Skin line", target: nil, action: nil)
    let regionButton = NSButton(title: "Region", target: nil, action: nil)
    let gainSlider = ResettableSlider(value: Double(ScopeSettings.defaultGain), minValue: 0.2, maxValue: 4, target: nil, action: nil)

    /// `closable` is only for a helper started by hand. Under the plug-in there is no
    /// close button: visibility belongs to Show / Hide Scopes in Lightroom.
    init(settings: ScopeSettings, closable: Bool = false) {
        self.settings = settings
        var style: NSWindow.StyleMask = [.titled, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel]
        if closable { style.insert(.closable) }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                            styleMask: style, backing: .buffered, defer: true)
        panel.title = "Scopes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.contentMinSize = Self.minimumContentSize
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        apply(settings: settings, notify: false)
        restoreFrame()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public updates

    func show(_ visible: Bool) {
        guard let window else { return }
        if visible {
            if !window.isVisible { window.orderFrontRegardless() }
        } else if window.isVisible {
            window.orderOut(nil)
        }
    }

    func display(_ output: FrameProcessor.Output) {
        waveformView.trace = output.waveform
        waveformView.mode = output.waveformMode
        vectorscopeView.trace = output.vectorscope
        vectorscopeView.chromaAtEdge = output.chromaAtEdge
        navigatorView.image = output.navigatorImage
        let badge = output.region == nil ? nil : "REGION"
        waveformView.badge = badge
        vectorscopeView.badge = badge
        setMessage(nil)
    }

    func clearTraces() {
        waveformView.trace = nil
        vectorscopeView.trace = nil
        navigatorView.image = nil
    }

    /// Back to measuring the whole image (e.g. when a different photo is selected).
    func resetRegion() {
        guard settings.region != nil else { return }
        var s = settings
        s.region = nil
        apply(settings: s, notify: true)
    }

    func setMessage(_ message: String?) {
        waveformView.message = message
        vectorscopeView.message = message
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private(set) var isShowingUpdating = false

    func setUpdating(_ updating: Bool) {
        guard updating != isShowingUpdating else { return }
        isShowingUpdating = updating
        if updating { updatingIndicator.startAnimation(nil) } else { updatingIndicator.stopAnimation(nil) }
    }

    // MARK: - Frame persistence

    private static let frameKey = "ScopesPanelFrame"

    /// Restores the saved frame, but only if it is sane and on a connected screen;
    /// a frame saved on a now-disconnected or larger display must not come back huge.
    private func restoreFrame() {
        guard let window else { return }
        // Frames saved by 1.0.0's frame autosave could be huge; ignore them.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame ScopesPanel")
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(Self.clamp(frame, to: screen.visibleFrame, minimum: window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size), display: false)
                return
            }
        }
        window.center()
    }

    static func clamp(_ frame: NSRect, to visible: NSRect, minimum: NSSize) -> NSRect {
        var f = frame
        f.size.width = min(max(f.width, minimum.width), visible.width)
        f.size.height = min(max(f.height, minimum.height), visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    private func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }

        layoutControl.segmentCount = ScopeLayout.allCases.count
        for (i, l) in ScopeLayout.allCases.enumerated() { layoutControl.setLabel(l.displayName, forSegment: i) }
        modeControl.segmentCount = WaveformMode.allCases.count
        for (i, m) in WaveformMode.allCases.enumerated() { modeControl.setLabel(m.displayName, forSegment: i) }
        zoomControl.segmentCount = 2
        zoomControl.setLabel("1×", forSegment: 0)
        zoomControl.setLabel("2×", forSegment: 1)
        layoutControl.toolTip = "Which scopes to show"
        modeControl.toolTip = "Waveform mode"
        zoomControl.toolTip = "Vectorscope magnification"
        colorizeCheckbox.toolTip = "Colour the vectorscope trace by hue"
        skinCheckbox.toolTip = "Show the skin tone indicator line"
        gainSlider.toolTip = "Trace intensity (double-click to reset)"
        regionButton.toolTip = "Measure only part of the image: drag on the thumbnail. Double-click it to measure the whole image again."
        regionButton.setButtonType(.pushOnPushOff)
        regionButton.bezelStyle = .rounded
        regionButton.controlSize = .small
        regionButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        regionButton.target = self
        regionButton.action = #selector(controlChanged(_:))
        navigatorView.message = "No image"
        navigatorView.onRegionChanged = { [weak self] region in
            guard let self else { return }
            var s = self.settings
            s.region = region
            self.apply(settings: s, notify: true)
        }

        for control in [layoutControl, modeControl, zoomControl] {
            control.controlSize = .small
            control.segmentStyle = .rounded
            control.trackingMode = .selectOne
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        for control in [colorizeCheckbox, skinCheckbox] {
            control.controlSize = .small
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        gainSlider.controlSize = .small
        gainSlider.isContinuous = true
        gainSlider.defaultValue = Double(ScopeSettings.defaultGain)
        gainSlider.target = self
        gainSlider.action = #selector(controlChanged(_:))
        gainSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let intensityLabel = NSTextField(labelWithString: "Intensity")
        intensityLabel.controlSize = .small
        intensityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        updatingIndicator.style = .spinning
        updatingIndicator.controlSize = .small
        updatingIndicator.isIndeterminate = true
        updatingIndicator.isDisplayedWhenStopped = false
        updatingIndicator.toolTip = "Waiting for Lightroom to render the latest change"

        let toolbar = NSStackView(views: [layoutControl, regionButton, modeControl, zoomControl, colorizeCheckbox, skinCheckbox,
                                          intensityLabel, gainSlider, updatingIndicator, statusLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        toolbar.setCustomSpacing(4, after: intensityLabel)
        toolbar.setCustomSpacing(6, after: updatingIndicator)
        // In a narrow window, drop the least important items instead of overflowing.
        toolbar.setClippingResistancePriority(.defaultLow, for: .horizontal)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 100), for: statusLabel)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 200), for: intensityLabel)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 300), for: skinCheckbox)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 400), for: colorizeCheckbox)
        toolbar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 450), for: gainSlider)

        let content = ScopesContentView(toolbar: toolbar, waveformView: waveformView, vectorscopeView: vectorscopeView,
                                        navigatorView: navigatorView)
        contentView = content
        window.contentView = content
    }

    private func apply(settings: ScopeSettings, notify: Bool) {
        self.settings = settings
        layoutControl.selectedSegment = ScopeLayout.allCases.firstIndex(of: settings.layout) ?? 0
        modeControl.selectedSegment = WaveformMode.allCases.firstIndex(of: settings.waveformMode) ?? 0
        zoomControl.selectedSegment = settings.vectorscopeZoom == 2 ? 1 : 0
        colorizeCheckbox.state = settings.colorizeVectorscope ? .on : .off
        skinCheckbox.state = settings.showSkinToneLine ? .on : .off
        gainSlider.doubleValue = Double(settings.gain)

        contentView.layoutMode = settings.layout
        contentView.showsNavigator = settings.showsRegionSelector
        regionButton.state = settings.showsRegionSelector ? .on : .off
        navigatorView.region = settings.region
        modeControl.isEnabled = settings.layout != .vectorscope
        let vectorscopeShown = settings.layout != .waveform
        zoomControl.isEnabled = vectorscopeShown
        colorizeCheckbox.isEnabled = vectorscopeShown
        skinCheckbox.isEnabled = vectorscopeShown
        vectorscopeView.showSkinToneLine = settings.showSkinToneLine

        if notify {
            settings.save()
            onSettingsChanged?(settings)
        }
    }

    @objc func controlChanged(_ sender: Any?) {
        var s = settings
        s.layout = ScopeLayout.allCases[max(0, layoutControl.selectedSegment)]
        s.waveformMode = WaveformMode.allCases[max(0, modeControl.selectedSegment)]
        s.vectorscopeZoom = zoomControl.selectedSegment == 1 ? 2 : 1
        s.colorizeVectorscope = colorizeCheckbox.state == .on
        s.showSkinToneLine = skinCheckbox.state == .on
        s.gain = gainSlider.floatValue
        s.showsRegionSelector = regionButton.state == .on
        // Hiding the navigator also goes back to measuring the whole image, so the
        // scopes never silently measure a region you can't see.
        if !s.showsRegionSelector { s.region = nil }
        guard s != settings else { return }
        apply(settings: s, notify: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        onUserClosed?()
    }
}
