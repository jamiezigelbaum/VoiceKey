import AVFoundation
import Foundation
import VoiceKeyObjCShield

enum RealtimeAudioEngineError: LocalizedError {
    case microphoneDenied
    case missingInputFormat
    case conversionFailed
    case audioSystemFailure(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is not enabled for VoiceKey."
        case .missingInputFormat:
            return "VoiceKey could not read the current microphone format."
        case .conversionFailed:
            return "VoiceKey could not convert microphone audio."
        case let .audioSystemFailure(reason):
            return "The audio system reported a failure: \(reason)"
        }
    }
}

protocol RealtimeAudioEngineProtocol: AnyObject {
    func setFatalFailureHandler(_ handler: (() -> Void)?)
    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void)
    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws
    func stop()
    func stopPlayback()
    func playPCM16(_ data: Data)
}

extension RealtimeAudioEngineProtocol {
    func setFatalFailureHandler(_ handler: (() -> Void)?) {}
}

struct RealtimeAudioInputActivity: Equatable {
    var rms: Float
    var peak: Float
}

/// Capture and playback share ONE AVAudioEngine so that Apple's voice
/// processing (echo cancellation) has the playback signal as its reference.
/// Splitting capture and playback across two engines is unsupported and
/// yields a silenced input tap. All engine state is confined to `queue`;
/// AVFoundation calls that can raise Objective-C exceptions (uncatchable
/// from Swift) run behind VKCatchObjCException so a mid-route-change
/// failure surfaces as an error instead of aborting the process.
final class RealtimeAudioEngine: RealtimeAudioEngineProtocol {
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "VoiceKey.RealtimeAudioEngine")
    private let queueKey = DispatchSpecificKey<Void>()
    private var inputConverter: AVAudioConverter?
    private var inputConverterSourceFormat: AVAudioFormat?
    private var isInputStreaming = false
    private var storedInputHandler: ((Data) -> Void)?
    private var storedActivityHandler: ((RealtimeAudioInputActivity) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var rebuildWorkItem: DispatchWorkItem?
    private var rebuildAttempts = 0
    private var onFatalFailure: (() -> Void)?
    private(set) var isEchoCancellationActive = false

    private static let rebuildDebounce: TimeInterval = 0.4
    private static let maxRebuildAttempts = 3

    private let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        queue.setSpecific(key: queueKey, value: ())
        onQueue {
            try? self.buildEngine()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func setFatalFailureHandler(_ handler: (() -> Void)?) {
        onQueue {
            self.onFatalFailure = handler
        }
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {
        try onQueueThrowing {
            guard self.isInputStreaming == false else { return }
            self.storedInputHandler = inputHandler
            self.storedActivityHandler = activityHandler
            do {
                try self.startCapture()
                self.isInputStreaming = true
            } catch {
                self.storedInputHandler = nil
                self.storedActivityHandler = nil
                self.teardownEngine()
                throw error
            }
        }
    }

    func stop() {
        onQueueSync {
            self.isInputStreaming = false
            self.storedInputHandler = nil
            self.storedActivityHandler = nil
            self.rebuildWorkItem?.cancel()
            self.rebuildWorkItem = nil
            self.rebuildAttempts = 0
            self.teardownEngine()
        }
    }

    func stopPlayback() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = VKCatchObjCException {
                self.playerNode.stop()
            }
        }
    }

    func playPCM16(_ data: Data) {
        guard data.count >= 2,
              let buffer = makeOutputBuffer(from: data) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.startEngineIfNeeded()
                try self.shielded("schedule playback") {
                    if self.playerNode.isPlaying == false {
                        self.playerNode.play()
                    }
                    self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
                }
            } catch {
                // Playback is best-effort; a route change mid-schedule will
                // be recovered by the configuration-change rebuild.
            }
        }
    }

    // MARK: - Engine lifecycle (queue-confined)

    // Order is load-bearing (verified empirically on hardware, 2026-07-23):
    // the player graph must be wired BEFORE voice processing is enabled —
    // enabling VP first fails engine start with kAUInitialize (-10875) —
    // and the input tap must be installed BEFORE the engine starts or the
    // tap can deliver silence.
    private func buildEngine() throws {
        try shielded("build playback graph") {
            self.engine.attach(self.playerNode)
            self.engine.connect(
                self.playerNode,
                to: self.engine.mainMixerNode,
                format: self.realtimeFormat
            )
        }
        try configureVoiceProcessing()
        observeConfigurationChanges(of: engine)
    }

    private func configureVoiceProcessing() throws {
        var inputNode: AVAudioInputNode?
        var outputNode: AVAudioOutputNode?
        try shielded("acquire voice processing nodes") {
            inputNode = self.engine.inputNode
            outputNode = self.engine.outputNode
        }
        guard let inputNode, let outputNode else {
            throw RealtimeAudioEngineError.audioSystemFailure(
                "acquire voice processing nodes: unavailable"
            )
        }
        do {
            try shielded("enable voice processing") {
                try inputNode.setVoiceProcessingEnabled(true)
                try outputNode.setVoiceProcessingEnabled(true)
            }
            isEchoCancellationActive = true
        } catch {
            _ = VKCatchObjCException {
                try? inputNode.setVoiceProcessingEnabled(false)
                try? outputNode.setVoiceProcessingEnabled(false)
            }
            isEchoCancellationActive = false
        }
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.scheduleRebuild()
            }
        }
    }

    private func startCapture() throws {
        var inputNode: AVAudioInputNode?
        var inputFormat: AVAudioFormat?
        try shielded("read microphone format") {
            let node = self.engine.inputNode
            inputNode = node
            inputFormat = node.outputFormat(forBus: 0)
        }
        guard let inputNode, let inputFormat else {
            throw RealtimeAudioEngineError.missingInputFormat
        }
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RealtimeAudioEngineError.missingInputFormat
        }

        inputConverter = nil
        inputConverterSourceFormat = nil

        try shielded("install microphone tap") {
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.queue.async {
                    guard self.isInputStreaming,
                          let inputHandler = self.storedInputHandler,
                          let activityHandler = self.storedActivityHandler else { return }
                    do {
                        let result = try self.convertInputBuffer(buffer, sourceFormat: inputFormat)
                        if result.pcm.isEmpty == false {
                            activityHandler(result.activity)
                            inputHandler(result.pcm)
                        }
                    } catch {
                        // Audio taps cannot surface errors synchronously; provider-level
                        // connection status will report if no usable audio is accepted.
                    }
                }
            }
        }

        try startEngineIfNeeded()
    }

    private func startEngineIfNeeded() throws {
        guard engine.isRunning == false else { return }
        try shielded("start audio engine") {
            self.engine.prepare()
            try self.engine.start()
        }
    }

    private func teardownEngine() {
        Self.performTeardown(
            removeTap: {
                self.engine.inputNode.removeTap(onBus: 0)
            },
            stopPlayback: {
                self.playerNode.stop()
            },
            stopEngine: {
                self.engine.stop()
            },
            shield: shielded
        )
        inputConverter = nil
        inputConverterSourceFormat = nil
    }

    static func performTeardown(
        removeTap: @escaping () throws -> Void,
        stopPlayback: @escaping () throws -> Void,
        stopEngine: @escaping () throws -> Void,
        shield: (String, () throws -> Void) throws -> Void
    ) {
        try? shield("remove microphone tap") {
            try removeTap()
        }
        try? shield("stop audio playback") {
            try stopPlayback()
        }
        try? shield("stop audio engine") {
            try stopEngine()
        }
    }

    /// A device switch (e.g. connecting AirPods) invalidates the engine's
    /// cached formats. Route transitions fire several configuration-change
    /// notifications in a burst and the new route needs time to settle, so
    /// rebuilds are debounced and retried with backoff.
    private func scheduleRebuild(after delay: TimeInterval = RealtimeAudioEngine.rebuildDebounce) {
        rebuildWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performRebuild()
        }
        rebuildWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func performRebuild() {
        rebuildWorkItem = nil
        teardownEngine()

        guard isInputStreaming else {
            rebuildAttempts = 0
            return
        }

        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        do {
            try buildEngine()
            try startCapture()
            rebuildAttempts = 0
        } catch {
            rebuildAttempts += 1
            if rebuildAttempts <= RealtimeAudioEngine.maxRebuildAttempts {
                scheduleRebuild(after: 0.5 * Double(rebuildAttempts))
            } else {
                rebuildAttempts = 0
                isInputStreaming = false
                storedInputHandler = nil
                storedActivityHandler = nil
                teardownEngine()
                onFatalFailure?()
            }
        }
    }

    // MARK: - Queue and exception plumbing

    private func onQueue(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            action()
        } else {
            queue.sync(execute: action)
        }
    }

    private func onQueueSync(_ action: () -> Void) {
        onQueue(action)
    }

    private func onQueueThrowing(_ action: () throws -> Void) throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try action()
        } else {
            try queue.sync(execute: action)
        }
    }

    private func shielded(_ operation: String, _ block: () throws -> Void) throws {
        var swiftError: Error?
        let exception = VKCatchObjCException {
            do {
                try block()
            } catch {
                swiftError = error
            }
        }
        if let exception {
            let reason = exception.reason ?? exception.name.rawValue
            throw RealtimeAudioEngineError.audioSystemFailure("\(operation): \(reason)")
        }
        if let swiftError {
            throw swiftError
        }
    }

    // MARK: - Conversion

    private func convertInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat
    ) throws -> InputConversionResult {
        let converted = try convertInputBufferToRealtimeFloat(buffer, sourceFormat: sourceFormat)
        guard let channel = converted.floatChannelData?[0] else {
            throw RealtimeAudioEngineError.conversionFailed
        }

        let samples = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        return InputConversionResult(
            pcm: RealtimePCM16Codec.encode(samples: samples),
            activity: inputActivity(samples: samples)
        )
    }

    private func inputActivity(samples: UnsafeBufferPointer<Float>) -> RealtimeAudioInputActivity {
        guard samples.isEmpty == false else {
            return RealtimeAudioInputActivity(rms: 0, peak: 0)
        }

        var sum: Float = 0
        var peak: Float = 0
        for sample in samples {
            let value = abs(sample)
            sum += value * value
            peak = max(peak, value)
        }
        return RealtimeAudioInputActivity(
            rms: sqrt(sum / Float(samples.count)),
            peak: peak
        )
    }

    private func convertInputBufferToRealtimeFloat(
        _ buffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let sourceChanged = inputConverterSourceFormat?.sampleRate != sourceFormat.sampleRate
            || inputConverterSourceFormat?.channelCount != sourceFormat.channelCount
            || inputConverterSourceFormat?.commonFormat != sourceFormat.commonFormat

        if inputConverter == nil || sourceChanged {
            let converter = AVAudioConverter(from: sourceFormat, to: realtimeFormat)
            // Voice processing can expose a multichannel input stream (9ch
            // observed live); default multichannel-to-mono conversion yields
            // silence, so map the first channel explicitly.
            if sourceFormat.channelCount > 1 {
                converter?.channelMap = [0]
            }
            inputConverter = converter
            inputConverterSourceFormat = sourceFormat
        }

        guard let converter = inputConverter else {
            throw RealtimeAudioEngineError.conversionFailed
        }

        let ratio = realtimeFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 8))
        guard let converted = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: capacity) else {
            throw RealtimeAudioEngineError.conversionFailed
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        if conversionError != nil {
            throw RealtimeAudioEngineError.conversionFailed
        }
        return converted
    }

    private func makeOutputBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: realtimeFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        let samples = RealtimePCM16Codec.decode(data)
        for index in 0..<frameCount {
            channel[index] = samples[index]
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}

private struct InputConversionResult {
    var pcm: Data
    var activity: RealtimeAudioInputActivity
}
