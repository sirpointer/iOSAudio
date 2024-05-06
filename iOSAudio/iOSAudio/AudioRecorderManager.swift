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
    case failure(AudioRecorderManager.AudioEngineError)
    case started
    case streaming(buffer: AVAudioPCMBuffer)
    case converted(data: [Float], time: Float64)
}

final class AudioRecorderManager: NSObject {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    private let inputBus: AVAudioNodeBus = 0
    private let outputBus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount = 1024

    let sampleRate: Int
    let numberOfChannels: UInt32
    let audioFormat: AVAudioCommonFormat

    private let dataPublisher = PublishSubject<AudioRecorderData>()
    private func publish(_ value: AudioRecorderData) {
        dataPublisher.onNext(value)
    }

    var outputData: Observable<AudioRecorderData> { dataPublisher }
    private (set) var status: EngineStatus = .notInitialized

    private var streamingInProgress: Bool = false

    init(sampleRate: Int = 16000, numberOfChannels: UInt32 = 1, audioFormat: AVAudioCommonFormat = .pcmFormatInt16) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.audioFormat = audioFormat
    }

    func setupEngine() {
        engine.reset()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: outputBus)

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, audioTime in
            self?.convert(buffer: buffer, time: audioTime.audioTimeStamp.mSampleTime)
        }
        inputNode.installTap(onBus: inputBus, bufferSize: bufferSize, format: inputFormat, block: tapBlock)
        engine.prepare()
        setupConverter(inputFormat: inputFormat)

        status = .ready
        print("[AudioEngine]: Setup finished.")
    }

    private func setupConverter(inputFormat: AVAudioFormat) {
        if let outputFormat = AVAudioFormat(commonFormat: audioFormat, sampleRate: Double(sampleRate), channels: numberOfChannels, interleaved: false) {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, time: Float64) {
        guard let converter else {
            status = .failed
            streamingInProgress = false
            print("[AudioEngine]: Convertor doesn't exist.")
            publish(.failure(.converterMissing))
            return
        }
        let outputFormat = converter.outputFormat

        let targetFrameCapacity = AVAudioFrameCount(outputFormat.sampleRate) * buffer.frameLength / AVAudioFrameCount(buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            status = .failed
            streamingInProgress = false
            print("[AudioEngine]: Cannot create AVAudioPCMBuffer.")
            publish(.failure(.cannotCreatePcmBuffer))
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { [weak buffer] _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        switch status {
        case .haveData:
            publish(.streaming(buffer: buffer))
            let arraySize = Int(buffer.frameLength)
            guard let start = convertedBuffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: start, count: arraySize))
            if !streamingInProgress {
                streamingInProgress = true
                publish(.started)
            }
            publish(.converted(data: samples, time: time))
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
            publish(.failure(.internalError(error)))
            print("[AudioEngine]: \(error.localizedDescription)")
            return
        }

        print("[AudioEngine]: Started tapping microphone.")
    }

    func stop() { 
        engine.stop()
        engine.reset()
        engine.inputNode.removeTap(onBus: inputBus)
        setupEngine()
    }
}

extension AudioRecorderManager {
    enum AudioEngineError: Error, LocalizedError {
        case converterMissing
        case cannotCreatePcmBuffer
        case noInputChannel
        case internalError(Error)
    }

    enum EngineStatus {
        case notInitialized
        case ready
        case recording
        case failed
    }
}
