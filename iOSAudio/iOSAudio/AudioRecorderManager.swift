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
    case soundCaptured(buffers: [AVAudioPCMBuffer])
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
    private let bufferSize: AVAudioFrameCount = 3200

    private var buffers: [AVAudioPCMBuffer] = []

    private let recorderQueue = DispatchQueue(label: "audioRecorderManager", qos: .userInitiated)

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat
    let targetChunkDuration: TimeInterval

    private let dataPublisher = PublishSubject<AudioRecorderData>()
    private func publish(_ value: AudioRecorderData) {
        dataPublisher.onNext(value)
    }

    var outputData: Observable<AudioRecorderData> { dataPublisher }
    private(set) var status: EngineStatus = .notInitialized
    private(set) var streamingInProgress: Bool = false

    init(sampleRate: Double = 16000, numberOfChannels: UInt32 = 1, commonFormat: AVAudioCommonFormat = .pcmFormatInt16, targetChunkDuration: TimeInterval) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
        self.targetChunkDuration = targetChunkDuration
    }

    func setupEngine() throws {
        engine.reset()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: outputBus)

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, time in
            self?.recorderQueue.async { [weak self] in
                self?.bufferRecorded(buffer: buffer, time: time)
            }
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

    func bufferRecorded(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        do {
            let (status, outputBuffer, error) = try convert(buffer: buffer)

            switch status {
            case .haveData:
                outputBufferReady(outputBuffer)

                if !streamingInProgress {
                    streamingInProgress = true
                    publish(.started)
                }
                print(time.sampleTime)
                print("[AudioEngine]: Buffer recorded, \(outputBuffer.frameLength), \(outputBuffer.duration) sec")
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
        } catch let error as AudioRecorderManagerError {
            self.status = .failed
            streamingInProgress = false
            publish(.failure(error))
        } catch {
            self.status = .failed
            streamingInProgress = false
            publish(.failure(.internalError(error)))
        }
    }

    private func convert(buffer: AVAudioPCMBuffer) throws -> (AVAudioConverterOutputStatus, AVAudioPCMBuffer, NSError?) {
        guard let converter else {
            print("[AudioEngine]: Convertor doesn't exist.")
            throw AudioRecorderManagerError.converterMissing
        }
        let outputFormat = converter.outputFormat

        let targetFrameCapacity = outputFormat.getTargetFrameCapacity(for: buffer)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            print("[AudioEngine]: Cannot create AVAudioPCMBuffer.")
            throw AudioRecorderManagerError.cannotCreatePcmBuffer
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        return (status, outputBuffer, error)
    }

    private func outputBufferReady(_ outputBuffer: AVAudioPCMBuffer) {
        let currentDuration = buffers.duration
        let outputBufferDuration = outputBuffer.duration

        guard currentDuration + outputBufferDuration >= targetChunkDuration else {
            buffers.append(outputBuffer)
            return
        }

        let currentDif = abs(targetChunkDuration - currentDuration)
        let newDif = abs(currentDuration + outputBufferDuration - targetChunkDuration)

        if newDif > currentDif {
            buffers.append(outputBuffer)
            publish(.soundCaptured(buffers: buffers))
            print("[AudioEngine]: Buffers sended, \(buffers.duration)")
            buffers.removeAll()
        } else {
            publish(.soundCaptured(buffers: buffers))
            print("[AudioEngine]: Buffers sended, \(buffers.duration)")
            buffers.removeAll()
            buffers.append(outputBuffer)
        }
    }

    func start() {
        buffers.removeAll()
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
        publish(.soundCaptured(buffers: buffers))
        buffers.removeAll()
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

private extension Array where Element == AVAudioPCMBuffer {
    var duration: TimeInterval {
        reduce(0, { $0 + $1.duration })
    }
}
