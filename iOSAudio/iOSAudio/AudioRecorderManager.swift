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
    case soundCaptured(buffers: [Buffer])
}

enum AudioRecorderManagerError: LocalizedError {
    case converterMissing
    case cannotCreatePcmBuffer
    case noInputChannel
    case internalError(Error)
    case engineStartFailure(Error)
    case cannotCreateConverter
}

struct Buffer: Comparable {
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime

    static func < (lhs: Buffer, rhs: Buffer) -> Bool {
        lhs.time.sampleTime < rhs.time.sampleTime
    }
}

final class AudioRecorderManager: NSObject {
    private var engine: AVAudioEngine
    private var converter: AVAudioConverter?

    private var audioInputNode: AVAudioInputNode { engine.inputNode }
    private var inputFormat: AVAudioFormat {
        audioInputNode.outputFormat(forBus: outputBus)
    }

    private let inputBus: AVAudioNodeBus = 0
    private let outputBus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount = 8192

    private var buffers: [Buffer] = []

    private let recorderQueue = DispatchQueue(label: "audioRecorderManager", qos: .default)
    private lazy var scheduler = SerialDispatchQueueScheduler(queue: recorderQueue, internalSerialQueueName: recorderQueue.label)

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

    init(sampleRate: Double = 16000, numberOfChannels: UInt32 = 1, commonFormat: AVAudioCommonFormat = .pcmFormatInt16, targetChunkDuration: TimeInterval, engine: AVAudioEngine = AVAudioEngine()) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
        self.targetChunkDuration = targetChunkDuration
        self.engine = engine
    }

    // MARK: Setup Recorder
    func setupRecorder() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.setupRecorder(observer: observer)
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }

    private func setupRecorder(observer: (Result<Void, Error>) -> Void) {
        let inputFormat = audioInputNode.outputFormat(forBus: outputBus)

        do {
            try setupConverter(inputFormat: inputFormat)
        } catch {
            observer(.failure(error))
        }
        status = .ready
        print("[AudioEngine]: Setup finished.")
        observer(.success(()))
    }

    private func setupConverter(inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: false) else {
            throw AudioRecorderManagerError.cannotCreateConverter
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    // MARK: Start
    func start() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.startRecording(observer: observer)
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }

    private func startRecording(observer: @escaping (Result<Void, Error>) -> Void) {
        buffers.removeAll(keepingCapacity: true)

        guard audioInputNode.inputFormat(forBus: inputBus).channelCount > 0 else {
            print("[AudioEngine]: No input is available.")
            streamingInProgress = false
            observer(.failure(AudioRecorderManagerError.noInputChannel))
            status = .failed
            return
        }

        prepareEngine()

        do {
            try engine.start()
            status = .recording
        } catch {
            streamingInProgress = false
            observer(.failure(AudioRecorderManagerError.engineStartFailure(error)))
            print("[AudioEngine]: \(error.localizedDescription)")
            return
        }

        observer(.success(()))
        print("[AudioEngine]: Started tapping microphone.")
    }

    private func prepareEngine() {
        let inputFormat = audioInputNode.outputFormat(forBus: outputBus)
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, time in
            self?.recorderQueue.async { [weak self] in
                self?.bufferRecorded(buffer: buffer, time: time)
            }
        }
        audioInputNode.installTap(onBus: inputBus, bufferSize: bufferSize, format: inputFormat, block: tapBlock)
        engine.prepare()
    }

    // MARK: Buffer Recorded
    private func bufferRecorded(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        do {
            let (status, outputBuffer, error) = try convert(buffer: buffer)

            switch status {
            case .haveData:
                outputBufferReady(.init(buffer: outputBuffer, time: time))

                if !streamingInProgress {
                    streamingInProgress = true
                    publish(.started)
                }
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

    private func outputBufferReady(_ outputBuffer: Buffer) {
        let currentDuration = buffers.map(\.buffer).duration
        let outputBufferDuration = outputBuffer.buffer.duration

        guard currentDuration + outputBufferDuration >= targetChunkDuration else {
            buffers.append(outputBuffer)
            return
        }

        let currentDif = abs(targetChunkDuration - currentDuration)
        let newDif = abs(currentDuration + outputBufferDuration - targetChunkDuration)

        if newDif > currentDif {
            buffers.append(outputBuffer)
            publish(.soundCaptured(buffers: buffers))
            print("[AudioEngine]: Buffers sended, \(buffers.map(\.buffer).duration)")
            buffers.removeAll()
        } else {
            publish(.soundCaptured(buffers: buffers))
            print("[AudioEngine]: Buffers sended, \(buffers.map(\.buffer).duration)")
            buffers.removeAll()
            buffers.append(outputBuffer)
        }
    }

    // MARK: Stop Recording
    func stop() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.stop(observer: observer)
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }

    private func stop(observer: (Result<Void, any Error>) -> Void) {
        publish(.soundCaptured(buffers: buffers))
        buffers.removeAll(keepingCapacity: true)
        audioInputNode.removeTap(onBus: inputBus)
        observer(.success(()))
        print("[AudioEngine]: Recording stopped.")
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
