import Foundation
import ScopesCore

enum ScopeLayout: String, CaseIterable {
    case both, waveform, vectorscope

    var displayName: String {
        switch self {
        case .both: return "Both"
        case .waveform: return "Waveform"
        case .vectorscope: return "Vectorscope"
        }
    }
}

/// User-facing scope settings, persisted in the helper's user defaults.
struct ScopeSettings: Equatable {
    var layout: ScopeLayout = .both
    var waveformMode: WaveformMode = .rgbParade
    var vectorscopeZoom: Int = 1          // 1x or 2x
    var colorizeVectorscope = true
    var showSkinToneLine = true
    static let defaultGain: Float = 1.6
    var gain: Float = ScopeSettings.defaultGain
    /// Show the region navigator next to the scopes (persisted).
    var showsRegionSelector = false
    /// Area of the photo the scopes measure; nil = whole image. Deliberately not
    /// persisted: a region only makes sense for the photo it was drawn on.
    var region: ScopeRegion?

    var analyzerConfiguration: ScopeAnalyzerConfiguration {
        var c = ScopeAnalyzerConfiguration()
        c.vectorscopeChromaAtEdge = ScopeAnalyzerConfiguration.defaultChromaAtEdge / Float(max(1, vectorscopeZoom))
        return c
    }

    var rendererStyle: ScopeRenderer.Style {
        .init(gain: gain, colorizeVectorscope: colorizeVectorscope)
    }

    private enum Key {
        static let layout = "layout"
        static let waveformMode = "waveformMode"
        static let zoom = "vectorscopeZoom"
        static let colorize = "colorizeVectorscope"
        static let skin = "showSkinToneLine"
        static let gain = "gain"
        static let regionSelector = "showsRegionSelector"
    }

    static func load(from defaults: UserDefaults = .standard) -> ScopeSettings {
        var s = ScopeSettings()
        if let v = defaults.string(forKey: Key.layout).flatMap(ScopeLayout.init(rawValue:)) { s.layout = v }
        if let v = defaults.string(forKey: Key.waveformMode).flatMap(WaveformMode.init(rawValue:)) { s.waveformMode = v }
        if defaults.object(forKey: Key.zoom) != nil { s.vectorscopeZoom = defaults.integer(forKey: Key.zoom) == 2 ? 2 : 1 }
        if defaults.object(forKey: Key.colorize) != nil { s.colorizeVectorscope = defaults.bool(forKey: Key.colorize) }
        if defaults.object(forKey: Key.skin) != nil { s.showSkinToneLine = defaults.bool(forKey: Key.skin) }
        if defaults.object(forKey: Key.gain) != nil {
            s.gain = min(4, max(0.2, defaults.float(forKey: Key.gain)))
        }
        if defaults.object(forKey: Key.regionSelector) != nil { s.showsRegionSelector = defaults.bool(forKey: Key.regionSelector) }
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValue, forKey: Key.layout)
        defaults.set(waveformMode.rawValue, forKey: Key.waveformMode)
        defaults.set(vectorscopeZoom, forKey: Key.zoom)
        defaults.set(colorizeVectorscope, forKey: Key.colorize)
        defaults.set(showSkinToneLine, forKey: Key.skin)
        defaults.set(gain, forKey: Key.gain)
        defaults.set(showsRegionSelector, forKey: Key.regionSelector)
    }
}
