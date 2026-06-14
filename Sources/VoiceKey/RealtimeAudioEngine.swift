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

final class RealtimeAudioEngine {
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "VoiceKey.RealtimeAudioEngine")
    private var inputConverter: AVAudioConverter?
    private var inputConverterSourceFormat: AVAudioFormat?

    private let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        outputEngine.attach(playerNode)
        outputEngine.connect(playerNode, to: outputEngine.mainMixerNode, format: realtimeFormat)
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

    func start(inputHandler: @escaping (Data) -> Void) throws {
        try startOutputIfNeeded()

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
                    let pcm = try self.convertInputBufferToPCM16(buffer, sourceFormat: inputFormat)
                    if pcm.isEmpty == false {
                        inputHandler(pcm)
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
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        playerNode.stop()
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

    private func convertInputBufferToPCM16(_ buffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) throws -> Data {
        let converted = try convertInputBufferToRealtimeFloat(buffer, sourceFormat: sourceFormat)
        guard let channel = converted.floatChannelData?[0] else {
            throw RealtimeAudioEngineError.conversionFailed
        }

        var output = Data(capacity: Int(converted.frameLength) * 2)
        for index in 0..<Int(converted.frameLength) {
            let sample = max(-1, min(1, channel[index]))
            let intSample = Int16(sample < 0 ? sample * 32768 : sample * 32767)
            var littleEndian = intSample.littleEndian
            output.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }
        return output
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

        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32768.0
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}
