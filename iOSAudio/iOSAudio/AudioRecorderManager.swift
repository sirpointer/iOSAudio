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
    private let bufferSize: AVAudioFrameCount = 4096

    private var buffers: [Buffer] = []
    private var skipFirstBuffer = true

    private let recorderQueue = DispatchQueue(label: "audioRecorderManager")

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

    init(sampleRate: Double, numberOfChannels: UInt32, commonFormat: AVAudioCommonFormat, targetChunkDuration: TimeInterval, engine: AVAudioEngine) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
        self.targetChunkDuration = targetChunkDuration
        self.engine = engine
    }

    // MARK: Setup Recorder
    func setupRecorder() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.setupRecorder(observer)
            return Disposables.create()
        }
    }

    func setupRecorder(_ callback: @escaping (Result<Void, Error>) -> Void) {
        AudioConfigurationManager.configurationQueue.async { [weak self] in
            guard let self else { return }
            let inputFormat = audioInputNode.outputFormat(forBus: outputBus)

            do {
                try setupConverter(inputFormat: inputFormat)
            } catch {
                callback(.failure(error))
            }
            status = .ready
            callback(.success(()))
        }
    }

    private func setupConverter(inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: true) else {
            throw AudioRecorderManagerError.cannotCreateConverter
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    // MARK: Start
    func start() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.start(observer)
            return Disposables.create()
        }
    }

    func start(_ callback: @escaping (Result<Void, Error>) -> Void) {
        recorderQueue.async { [weak self] in
            self?.startRecording(observer: callback)
        }
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
            if engine.isRunning {
                try engine.start()
            }
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
        guard !skipFirstBuffer else {
            skipFirstBuffer = false
            return
        }

        do {
            print("Buffer Recorded , \(buffer.frameLength), \(buffer.duration) sec")
            let (status, outputBuffer, error) = try convert(buffer: buffer)

            switch status {
            case .haveData:
                outputBufferReady(.init(buffer: outputBuffer, time: time))

                if !streamingInProgress {
                    streamingInProgress = true
                    publish(.started)
                }
                print("[AudioEngine]: Buffer converted, \(outputBuffer.frameLength), \(outputBuffer.duration) sec")
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
            self?.stop { observer(.success(())) }
            return Disposables.create()
        }
    }

    func stop(_ callback: @escaping () -> Void) {
        recorderQueue.async { [weak self] in
            guard let self else { return }
            publish(.soundCaptured(buffers: buffers))
            buffers.removeAll(keepingCapacity: true)
            audioInputNode.removeTap(onBus: inputBus)
            callback()
        }
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
