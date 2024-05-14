//
//  AudioRecorderManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 02.05.2024.
//

import Foundation
import AVFoundation
import RxSwift

enum AudioRecorderData {
    case failure(AudioRecorderManagerError)
    case started
    case soundCaptured(buffer: AVAudioPCMBuffer)
}

enum AudioRecorderManagerError: LocalizedError {
    case converterMissing
    case cannotCreatePcmBuffer
    case noInputChannel
    case internalError(Error)
    case engineStartFailure(Error)
    case cannotCreateConverter
}

final class AudioRecorderManager: NSObject {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    private let inputBus: AVAudioNodeBus = 0
    private let outputBus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount = 1024

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat

    private let dataPublisher = PublishSubject<AudioRecorderData>()
    private func publish(_ value: AudioRecorderData) {
        dataPublisher.onNext(value)
    }

    var outputData: Observable<AudioRecorderData> { dataPublisher }
    private(set) var status: EngineStatus = .notInitialized
    private(set) var streamingInProgress: Bool = false

    init(sampleRate: Double = 16000, numberOfChannels: UInt32 = 1, commonFormat: AVAudioCommonFormat = .pcmFormatInt16) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
    }

    func setupEngine() throws {
        engine.reset()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: outputBus)

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            self?.convert(buffer: buffer)
        }
        inputNode.installTap(onBus: inputBus, bufferSize: bufferSize, format: inputFormat, block: tapBlock)

        try setupConverter(inputFormat: inputFormat)

        engine.prepare()
        status = .ready
        print("[AudioEngine]: Setup finished.")
    }

    private func setupConverter(inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: false) else {
            throw AudioRecorderManagerError.cannotCreateConverter
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    func convert(buffer: AVAudioPCMBuffer) {
        guard let converter else {
            status = .failed
            streamingInProgress = false
            print("[AudioEngine]: Convertor doesn't exist.")
            publish(.failure(.converterMissing))
            return
        }
        let outputFormat = converter.outputFormat

        let targetFrameCapacity = outputFormat.getTargetFrameCapacity(for: buffer)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            status = .failed
            streamingInProgress = false
            print("[AudioEngine]: Cannot create AVAudioPCMBuffer.")
            publish(.failure(.cannotCreatePcmBuffer))
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        switch status {
        case .haveData:
            publish(.soundCaptured(buffer: convertedBuffer))

            if !streamingInProgress {
                streamingInProgress = true
                publish(.started)
            }
        case .error:
            if let error {
                streamingInProgress = false
                publish(.failure(.internalError(error)))
            }
            self.status = .failed
            print("[AudioEngine]: Converter failed, \(error?.localizedDescription ?? "Unknown error")")
        case .endOfStream:
            streamingInProgress = false
            print("[AudioEngine]: The end of stream has been reached. No data was returned.")
        case .inputRanDry:
            streamingInProgress = false
            print("[AudioEngine]: Converter input ran dry.")
        @unknown default:
            if let error = error {
                streamingInProgress = false
                publish(.failure(.internalError(error)))
            }
            print("[AudioEngine]: Unknown converter error")
        }
    }

    func start() {
        guard engine.inputNode.inputFormat(forBus: inputBus).channelCount > 0 else {
            print("[AudioEngine]: No input is available.")
            streamingInProgress = false
            publish(.failure(.noInputChannel))
            status = .failed
            return
        }

        do {
            try engine.start()
            status = .recording
        } catch {
            streamingInProgress = false
            publish(.failure(.engineStartFailure(error)))
            print("[AudioEngine]: \(error.localizedDescription)")
            return
        }

        print("[AudioEngine]: Started tapping microphone.")
    }

    func stop() throws {
        engine.stop()
        engine.reset()
        engine.inputNode.removeTap(onBus: inputBus)
        try setupEngine()
    }
}

extension AudioRecorderManager {
    enum EngineStatus {
        case notInitialized
        case ready
        case recording
        case failed
    }
}
