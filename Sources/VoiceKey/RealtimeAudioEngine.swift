import AVFoundation
import Foundation

enum RealtimeAudioEngineError: LocalizedError {
    case microphoneDenied
    case missingInputFormat
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is not enabled for VoiceKey."
        case .missingInputFormat:
            return "VoiceKey could not read the current microphone format."
        case .conversionFailed:
            return "VoiceKey could not convert microphone audio."
        }
    }
}

protocol RealtimeAudioEngineProtocol: AnyObject {
    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void)
    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws
    func stop()
    func stopPlayback()
    func playPCM16(_ data: Data)
}

struct RealtimeAudioInputActivity: Equatable {
    var rms: Float
    var peak: Float
}

final class RealtimeAudioEngine: RealtimeAudioEngineProtocol {
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "VoiceKey.RealtimeAudioEngine")
    private let stateLock = NSLock()
    private var inputConverter: AVAudioConverter?
    private var inputConverterSourceFormat: AVAudioFormat?
    private var isInputStreaming = false
    private var storedInputHandler: ((Data) -> Void)?
    private var storedActivityHandler: ((RealtimeAudioInputActivity) -> Void)?
    private var configurationObservers: [NSObjectProtocol] = []

    private let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        outputEngine.attach(playerNode)
        outputEngine.connect(playerNode, to: outputEngine.mainMixerNode, format: realtimeFormat)

        for engine in [inputEngine, outputEngine] {
            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
            configurationObservers.append(observer)
        }
    }

    deinit {
        for observer in configurationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // A device switch (e.g. connecting AirPods) invalidates the engines'
    // cached formats mid-session; restart capture against the new route
    // instead of letting the next tap install throw an ObjC exception.
    private func handleConfigurationChange() {
        queue.async { [weak self] in
            guard let self else { return }

            self.stateLock.lock()
            let wasStreaming = self.isInputStreaming
            let inputHandler = self.storedInputHandler
            let activityHandler = self.storedActivityHandler
            self.stateLock.unlock()

            self.inputEngine.inputNode.removeTap(onBus: 0)
            self.inputEngine.stop()
            self.outputEngine.stop()
            self.inputConverter = nil
            self.inputConverterSourceFormat = nil

            guard wasStreaming, let inputHandler, let activityHandler else { return }
            do {
                try self.startInput(
                    inputHandler: inputHandler,
                    activityHandler: activityHandler
                )
            } catch {
                self.stateLock.lock()
                self.isInputStreaming = false
                self.stateLock.unlock()
            }
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
        stateLock.lock()
        guard isInputStreaming == false else {
            stateLock.unlock()
            return
        }
        isInputStreaming = true
        storedInputHandler = inputHandler
        storedActivityHandler = activityHandler
        stateLock.unlock()

        do {
            try startInput(
                inputHandler: inputHandler,
                activityHandler: activityHandler
            )
        } catch {
            stateLock.lock()
            isInputStreaming = false
            stateLock.unlock()
            throw error
        }
    }

    private func startInput(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {
        try startOutputIfNeeded()

        if inputEngine.isRunning == false {
            inputEngine.reset()
        }

        let inputNode = inputEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RealtimeAudioEngineError.missingInputFormat
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async {
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

        inputEngine.prepare()
        try inputEngine.start()
    }

    func stop() {
        stateLock.lock()
        isInputStreaming = false
        storedInputHandler = nil
        storedActivityHandler = nil
        stateLock.unlock()

        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        stopPlayback()
        outputEngine.stop()
    }

    func stopPlayback() {
        queue.async { [weak self] in
            self?.playerNode.stop()
        }
    }

    func playPCM16(_ data: Data) {
        guard data.count >= 2,
              let buffer = makeOutputBuffer(from: data) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.startOutputIfNeeded()
                if self.playerNode.isPlaying == false {
                    self.playerNode.play()
                }
                self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
            } catch {
                return
            }
        }
    }

    private func startOutputIfNeeded() throws {
        if outputEngine.isRunning == false {
            outputEngine.prepare()
            try outputEngine.start()
        }
        if playerNode.isPlaying == false {
            playerNode.play()
        }
    }

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
            inputConverter = AVAudioConverter(from: sourceFormat, to: realtimeFormat)
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
