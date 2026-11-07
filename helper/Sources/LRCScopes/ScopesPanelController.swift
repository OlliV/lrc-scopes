import AppKit
import ScopesCore

/// A floating, non-activating HUD panel holding the scopes and their controls.
///
/// Non-activating matters: clicking the scopes must never take keyboard focus away
/// from Lightroom, or Develop shortcuts would stop working.
final class ScopesPanelController: NSWindowController, NSWindowDelegate {
    var onSettingsChanged: ((ScopeSettings) -> Void)?
    var onUserClosed: (() -> Void)?

    private(set) var settings: ScopeSettings
    private let waveformView = WaveformView(frame: .zero)
    private let vectorscopeView = VectorscopeView(frame: .zero)
    private let scopesStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")

    private let layoutControl = NSSegmentedControl()
    private let modeControl = NSSegmentedControl()
    private let zoomControl = NSSegmentedControl()
    private let colorizeCheckbox = NSButton(checkboxWithTitle: "Color", target: nil, action: nil)
    private let skinCheckbox = NSButton(checkboxWithTitle: "Skin line", target: nil, action: nil)
    private let gainSlider = NSSlider(value: 1.6, minValue: 0.2, maxValue: 4, target: nil, action: nil)

    init(settings: ScopeSettings) {
        self.settings = settings
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Scopes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.minSize = NSSize(width: 360, height: 220)
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        apply(settings: settings, notify: false)
        if !panel.setFrameUsingName("ScopesPanel") {
            panel.center()
        }
        panel.setFrameAutosaveName("ScopesPanel")
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
        setMessage(nil)
    }

    func clearTraces() {
        waveformView.trace = nil
        vectorscopeView.trace = nil
    }

    func setMessage(_ message: String?) {
        waveformView.message = message
        vectorscopeView.message = message
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

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
        gainSlider.toolTip = "Trace intensity"

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

        let toolbar = NSStackView(views: [layoutControl, modeControl, zoomControl, colorizeCheckbox, skinCheckbox,
                                          intensityLabel, gainSlider, statusLabel])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.setCustomSpacing(4, after: intensityLabel)
        toolbar.setHuggingPriority(.defaultHigh, for: .vertical)

        scopesStack.orientation = .horizontal
        scopesStack.distribution = .fill
        scopesStack.spacing = 1
        scopesStack.addArrangedSubview(waveformView)
        scopesStack.addArrangedSubview(vectorscopeView)
        // The vectorscope is square-ish; give the waveform the rest of the width.
        let vsWidth = vectorscopeView.widthAnchor.constraint(equalTo: scopesStack.heightAnchor)
        vsWidth.priority = .defaultHigh
        vsWidth.isActive = true
        waveformView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [toolbar, scopesStack])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            scopesStack.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    private func apply(settings: ScopeSettings, notify: Bool) {
        self.settings = settings
        layoutControl.selectedSegment = ScopeLayout.allCases.firstIndex(of: settings.layout) ?? 0
        modeControl.selectedSegment = WaveformMode.allCases.firstIndex(of: settings.waveformMode) ?? 0
        zoomControl.selectedSegment = settings.vectorscopeZoom == 2 ? 1 : 0
        colorizeCheckbox.state = settings.colorizeVectorscope ? .on : .off
        skinCheckbox.state = settings.showSkinToneLine ? .on : .off
        gainSlider.floatValue = settings.gain

        waveformView.isHidden = settings.layout == .vectorscope
        vectorscopeView.isHidden = settings.layout == .waveform
        let waveformVisible = settings.layout != .vectorscope
        modeControl.isEnabled = waveformVisible
        zoomControl.isEnabled = settings.layout != .waveform
        colorizeCheckbox.isEnabled = settings.layout != .waveform
        skinCheckbox.isEnabled = settings.layout != .waveform
        vectorscopeView.showSkinToneLine = settings.showSkinToneLine

        if notify {
            settings.save()
            onSettingsChanged?(settings)
        }
    }

    @objc private func controlChanged(_ sender: Any?) {
        var s = settings
        s.layout = ScopeLayout.allCases[max(0, layoutControl.selectedSegment)]
        s.waveformMode = WaveformMode.allCases[max(0, modeControl.selectedSegment)]
        s.vectorscopeZoom = zoomControl.selectedSegment == 1 ? 2 : 1
        s.colorizeVectorscope = colorizeCheckbox.state == .on
        s.showSkinToneLine = skinCheckbox.state == .on
        s.gain = gainSlider.floatValue
        guard s != settings else { return }
        apply(settings: s, notify: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onUserClosed?()
    }
}
