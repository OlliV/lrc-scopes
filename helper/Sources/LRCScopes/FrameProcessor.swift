import CoreGraphics
import Foundation
import os
import ScopesCore

/// Decodes, analyses and renders frames off the main thread.
///
/// Work is *latest-wins*: if several frames or settings changes arrive while a job is
/// running, only the most recent one is processed afterwards. The decoded image is
/// cached so settings changes (mode, zoom, intensity) don't re-decode the JPEG.
final class FrameProcessor {
    struct Output {
        var waveform: CGImage?
        var waveformMode: WaveformMode
        var vectorscope: CGImage?
        var chromaAtEdge: Float
        /// The whole decoded image, for the region navigator.
        var navigatorImage: CGImage?
        /// The region these scopes were computed for (nil = whole image).
        var region: ScopeRegion?
        var processingTime: TimeInterval
    }

    var onOutput: ((Output) -> Void)?
    var onError: ((String) -> Void)?

    /// Long edge of the analysis image. 1024 gives a 1024-column waveform for
    /// landscape images, more than any scope panel needs, at ~5 ms per frame.
    static let analysisMaxDimension = 1024

    private let log = Logger(subsystem: "com.lrcscopes.helper", category: "processing")
    private let queue = DispatchQueue(label: "com.lrcscopes.helper.processing", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingJPEG: Data?
    private var pendingSettings: ScopeSettings?
    private var scheduled = false

    // Processing-queue state.
    private var image: ImageBuffer?
    private var navigatorImage: CGImage?
    private var analysis: ScopeAnalysis?
    private var analysisConfig: ScopeAnalyzerConfiguration?
    private var analysisRegion: ScopeRegion?

    func submit(jpeg: Data?, settings: ScopeSettings) {
        lock.lock()
        if let jpeg { pendingJPEG = jpeg }
        pendingSettings = settings
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { [weak self] in self?.drain() } }
    }

    func clear() {
        queue.async { [weak self] in
            self?.image = nil
            self?.navigatorImage = nil
            self?.analysis = nil
            self?.analysisConfig = nil
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let jpeg = pendingJPEG
            let settings = pendingSettings
            pendingJPEG = nil
            pendingSettings = nil
            if settings == nil {
                scheduled = false
                lock.unlock()
                return
            }
            lock.unlock()
            process(jpeg: jpeg, settings: settings!)
        }
    }

    private func process(jpeg: Data?, settings: ScopeSettings) {
        let start = CFAbsoluteTimeGetCurrent()
        if let jpeg {
            do {
                let decoded = try ImageDecoder.decode(data: jpeg, maxDimension: Self.analysisMaxDimension)
                image = decoded
                navigatorImage = decoded.makeDisplayImage()
                analysis = nil
            } catch {
                log.error("Decode failed: \(String(describing: error), privacy: .public)")
                let message = String(describing: error)
                DispatchQueue.main.async { [weak self] in self?.onError?(message) }
                return
            }
        }
        guard let image else { return }

        let config = settings.analyzerConfiguration
        if analysis == nil || analysisConfig != config || analysisRegion != settings.region {
            let source = settings.region.map { image.cropped(to: $0) } ?? image
            analysis = ScopeAnalyzer.analyze(source, configuration: config)
            analysisConfig = config
            analysisRegion = settings.region
        }
        guard let analysis else { return }

        let style = settings.rendererStyle
        let wf = settings.layout != .vectorscope
            ? ScopeRenderer.renderWaveform(analysis.waveform, mode: settings.waveformMode, style: style).makeCGImage()
            : nil
        let vs = settings.layout != .waveform
            ? ScopeRenderer.renderVectorscope(analysis.vectorscope, style: style).makeCGImage()
            : nil
        let output = Output(waveform: wf, waveformMode: settings.waveformMode,
                            vectorscope: vs, chromaAtEdge: config.vectorscopeChromaAtEdge,
                            navigatorImage: navigatorImage, region: settings.region,
                            processingTime: CFAbsoluteTimeGetCurrent() - start)
        DispatchQueue.main.async { [weak self] in self?.onOutput?(output) }
    }
}
