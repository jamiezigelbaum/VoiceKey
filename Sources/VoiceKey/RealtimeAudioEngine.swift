import AVFoundation
import CoreAudio
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
    func setStateChangeHandler(_ handler: ((RealtimeAudioEngineState) -> Void)?)
    func refreshOutputRoute()
    func stateSnapshot() -> RealtimeAudioEngineState
    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void)
    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws
    func stop()
    func stopPlayback()
    func beginAssistantAudioTurn()
    func playPCM16(_ data: Data)
}

extension RealtimeAudioEngineProtocol {
    func setFatalFailureHandler(_ handler: (() -> Void)?) {}
    func setStateChangeHandler(_ handler: ((RealtimeAudioEngineState) -> Void)?) {}
    func refreshOutputRoute() {}
    func stateSnapshot() -> RealtimeAudioEngineState {
        RealtimeAudioEngineState(
            outputRoute: .headphones,
            isEchoCancellationActive: true,
            isPlaybackActive: false,
            currentAssistantPlayedDurationMilliseconds: 0
        )
    }
    func beginAssistantAudioTurn() {}
}

struct RealtimeAudioInputActivity: Equatable {
    var rms: Float
    var peak: Float
}

struct RealtimeAudioEngineState: Equatable {
    var outputRoute: RealtimeAudioOutputRoute
    var isEchoCancellationActive: Bool
    var isPlaybackActive: Bool
    var currentAssistantPlayedDurationMilliseconds: Int
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
    private var onStateChange: ((RealtimeAudioEngineState) -> Void)?
    private(set) var isEchoCancellationActive = false
    private var outputRoute = RealtimeAudioOutputRoute.unknown
    private var pendingPlaybackBufferCount = 0
    private var playbackGeneration = 0
    private var assistantTurnGeneration = 0
    private var currentTurnScheduledFrameCount: Int64 = 0
    private var currentTurnCompletedFrameCount: Int64 = 0
    private var currentSegmentBasePlayedFrameCount: Int64 = 0
    private var currentSegmentStartPlayerSampleTime: AVAudioFramePosition?

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

    func setStateChangeHandler(_ handler: ((RealtimeAudioEngineState) -> Void)?) {
        onQueue {
            self.onStateChange = handler
        }
    }

    func stateSnapshot() -> RealtimeAudioEngineState {
        onQueue {
            self.makeStateSnapshot()
        }
    }

    func refreshOutputRoute() {
        onQueue {
            self.refreshOutputRouteOnQueue()
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
            self.clearPlaybackTracking()
            _ = VKCatchObjCException {
                self.playerNode.stop()
            }
        }
    }

    func beginAssistantAudioTurn() {
        queue.async { [weak self] in
            guard let self else { return }
            self.assistantTurnGeneration += 1
            self.currentTurnScheduledFrameCount = 0
            self.currentTurnCompletedFrameCount = 0
            self.currentSegmentBasePlayedFrameCount = 0
            self.currentSegmentStartPlayerSampleTime = nil
            self.notifyStateChange()
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
                    if self.pendingPlaybackBufferCount == 0 {
                        self.currentSegmentBasePlayedFrameCount =
                            self.currentTurnCompletedFrameCount
                        self.currentSegmentStartPlayerSampleTime =
                            self.currentPlayerSampleTime() ?? 0
                    }
                    if self.playerNode.isPlaying == false {
                        self.playerNode.play()
                    }
                    let generation = self.playbackGeneration
                    let turnGeneration = self.assistantTurnGeneration
                    let scheduledFrameCount = Int64(buffer.frameLength)
                    self.playerNode.scheduleBuffer(
                        buffer,
                        completionCallbackType: .dataPlayedBack
                    ) { [weak self] _ in
                        self?.queue.async { [weak self] in
                            guard let self,
                                  self.playbackGeneration == generation else {
                                return
                            }
                            self.pendingPlaybackBufferCount = max(
                                0,
                                self.pendingPlaybackBufferCount - 1
                            )
                            if self.assistantTurnGeneration == turnGeneration {
                                self.currentTurnCompletedFrameCount +=
                                    scheduledFrameCount
                            }
                            if self.pendingPlaybackBufferCount == 0 {
                                self.currentSegmentBasePlayedFrameCount =
                                    self.currentTurnCompletedFrameCount
                                self.currentSegmentStartPlayerSampleTime = nil
                            }
                            self.notifyStateChange()
                        }
                    }
                    self.pendingPlaybackBufferCount += 1
                    self.currentTurnScheduledFrameCount += scheduledFrameCount
                    self.notifyStateChange()
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
        refreshOutputRouteOnQueue()
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
        clearPlaybackTracking()
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
            disableVoiceProcessing: {
                try self.engine.inputNode.setVoiceProcessingEnabled(false)
                try self.engine.outputNode.setVoiceProcessingEnabled(false)
                self.isEchoCancellationActive = false
            },
            shield: shielded
        )
        inputConverter = nil
        inputConverterSourceFormat = nil
    }

    /// `disableVoiceProcessing` runs last and it is not optional politeness:
    /// enabling voice processing puts the whole system output into the
    /// communications path, which ducks every other app to about half volume.
    /// Stopping the engine does not undo that — the nodes keep the setting and
    /// this engine instance outlives the session — so without this step the
    /// owner's music stayed quiet for as long as VoiceKey was running, long
    /// after the voice channel closed (reported on real hardware 2026-07-29).
    /// It must come after the engine is stopped: the setting cannot be changed
    /// on a running engine.
    static func performTeardown(
        removeTap: @escaping () throws -> Void,
        stopPlayback: @escaping () throws -> Void,
        stopEngine: @escaping () throws -> Void,
        disableVoiceProcessing: @escaping () throws -> Void,
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
        try? shield("disable voice processing") {
            try disableVoiceProcessing()
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

    // MARK: - Route and playback state (queue-confined)

    private func refreshOutputRouteOnQueue() {
        outputRoute = Self.readCurrentOutputRoute()
        notifyStateChange()
    }

    private func clearPlaybackTracking() {
        playbackGeneration += 1
        pendingPlaybackBufferCount = 0
        currentTurnScheduledFrameCount = 0
        currentTurnCompletedFrameCount = 0
        currentSegmentBasePlayedFrameCount = 0
        currentSegmentStartPlayerSampleTime = nil
        notifyStateChange()
    }

    private func notifyStateChange() {
        onStateChange?(makeStateSnapshot())
    }

    private func makeStateSnapshot() -> RealtimeAudioEngineState {
        RealtimeAudioEngineState(
            outputRoute: outputRoute,
            isEchoCancellationActive: isEchoCancellationActive,
            isPlaybackActive: pendingPlaybackBufferCount > 0,
            currentAssistantPlayedDurationMilliseconds:
                currentAssistantPlayedDurationMilliseconds()
        )
    }

    private func currentAssistantPlayedDurationMilliseconds() -> Int {
        let renderedFrames: Int64?
        if pendingPlaybackBufferCount == 0 {
            renderedFrames = currentTurnCompletedFrameCount
        } else if let start = currentSegmentStartPlayerSampleTime,
           let current = currentPlayerSampleTime() {
            renderedFrames = currentSegmentBasePlayedFrameCount
                + Int64(max(0, current - start))
        } else {
            renderedFrames = nil
        }
        return Self.playedDurationMilliseconds(
            renderedFrameCount: renderedFrames,
            scheduledFrameCount: currentTurnScheduledFrameCount,
            sampleRate: realtimeFormat.sampleRate
        )
    }

    private func currentPlayerSampleTime() -> AVAudioFramePosition? {
        guard playerNode.isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return playerTime.sampleTime
    }

    static func playedDurationMilliseconds(
        renderedFrameCount: Int64?,
        scheduledFrameCount: Int64,
        sampleRate: Double = 24_000
    ) -> Int {
        guard scheduledFrameCount > 0, sampleRate > 0 else { return 0 }
        // playerTime is preferred, but it keeps advancing while the player
        // node renders silence. Clamp it to bytes actually scheduled for the
        // current assistant item so truncate can never exceed played audio.
        let playedFrames = min(
            max(0, renderedFrameCount ?? scheduledFrameCount),
            scheduledFrameCount
        )
        return Int((Double(playedFrames) / sampleRate * 1_000).rounded(.down))
    }

    private static func readCurrentOutputRoute() -> RealtimeAudioOutputRoute {
        var defaultOutputDevice = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            &deviceSize,
            &defaultOutputDevice
        ) == noErr,
        defaultOutputDevice != kAudioObjectUnknown else {
            return .unknown
        }

        let transportValue = readUInt32(
            objectID: defaultOutputDevice,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let transport: RealtimeAudioOutputTransport
        switch transportValue {
        case kAudioDeviceTransportTypeBuiltIn:
            transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            transport = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            transport = .bluetoothLE
        case kAudioDeviceTransportTypeDisplayPort:
            transport = .displayPort
        case kAudioDeviceTransportTypeHDMI:
            transport = .hdmi
        case kAudioDeviceTransportTypeUSB:
            transport = .usb
        case kAudioDeviceTransportTypeAirPlay:
            transport = .airPlay
        case kAudioDeviceTransportTypeVirtual:
            transport = .virtual
        default:
            transport = .other
        }

        let dataSource: RealtimeAudioOutputDataSource
        if let sourceID = readUInt32(
            objectID: defaultOutputDevice,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioObjectPropertyScopeOutput
        ) ?? readUInt32(
            objectID: defaultOutputDevice,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioObjectPropertyScopeGlobal
        ),
        (dataSourceKind(
            sourceID: sourceID,
            deviceID: defaultOutputDevice,
            scope: kAudioObjectPropertyScopeOutput
        ) ?? dataSourceKind(
            sourceID: sourceID,
            deviceID: defaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )) == kAudioStreamTerminalTypeHeadphones {
            dataSource = .headphones
        } else {
            dataSource = .other
        }
        return RealtimeAudioOutputRoute(
            transport: transport,
            dataSource: dataSource
        )
    }

    private static func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func dataSourceKind(
        sourceID: UInt32,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var sourceID = sourceID
        var kind: UInt32 = 0
        return withUnsafeMutablePointer(to: &sourceID) { sourcePointer in
            withUnsafeMutablePointer(to: &kind) { kindPointer in
                var translation = AudioValueTranslation(
                    mInputData: sourcePointer,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: kindPointer,
                    mOutputDataSize: UInt32(MemoryLayout<UInt32>.size)
                )
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDataSourceKindForID,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                ) == noErr else {
                    return nil
                }
                return kindPointer.pointee
            }
        }
    }

    // MARK: - Queue and exception plumbing

    private func onQueue<T>(_ action: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return action()
        } else {
            return queue.sync(execute: action)
        }
    }

    private func onQueueSync<T>(_ action: () -> T) -> T {
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
