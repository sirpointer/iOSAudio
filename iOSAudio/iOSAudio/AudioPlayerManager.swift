//
//  AudioPlayerManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 02.05.2024.
//

import Foundation
import AVFoundation
import RxSwift

final class AudioPlayerManager {
    private let engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var converter = AVAudioConverter()

    private let recorderQueue = DispatchQueue(label: "audioPlayerManager", qos: .default)
    private lazy var scheduler = SerialDispatchQueueScheduler(queue: recorderQueue, internalSerialQueueName: recorderQueue.label)

    private let outputBus: AVAudioNodeBus = 0

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat

    init(sampleRate: Double = 16000, numberOfChannels: UInt32 = 1, commonFormat: AVAudioCommonFormat = .pcmFormatInt16) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFormat = converter.outputFormat
        let targetFrameCapacity = outputFormat.getTargetFrameCapacity(for: buffer)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData:
            return outputBuffer
        default:
            return nil
        }
    }
}

extension AudioPlayerManager {

    func setupPlayer() -> Single<Void> {
        Single.create { [weak self] observer in
            do {
                try self?.configurePlayer()
                observer(.success(()))
            } catch {
                observer(.failure(error))
            }
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }

    private func configurePlayer() throws {
        guard let inputFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: false) else {
            throw AudioPlayerManagerError.incorrectInputFormat
        }
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: outputBus)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioPlayerManagerError.cannotConfigureConverter
        }
        self.converter = converter
        try engine.start()
    }


    func play(_ buffers: [AVAudioPCMBuffer]) -> Single<Void> {
        Single.create { [weak self] observer in
            self?.playBuffers(buffers: buffers, observer: observer)
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }

    private func playBuffers(buffers: [AVAudioPCMBuffer], observer: @escaping (Result<Void, Error>) -> Void) {
        playerNode.stop()
        let buffers = buffers.compactMap { convertBuffer($0) }
        scheduleBuffers(buffers: buffers, observer: observer)
        playerNode.play()
    }

    private func scheduleBuffers(buffers: [AVAudioPCMBuffer], observer: @escaping (Result<Void, Error>) -> Void) {
        for (index, buffer) in buffers.enumerated() {
            let callback = index == buffers.count - 1 ? { [weak self] in
                observer(.success(()))
                self?.recorderQueue.async { [weak self] in
                    self?.playerNode.stop()
                }
            } : nil
            playerNode.scheduleBuffer(buffer) { callback?() }
        }
    }

    func stop() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.playerNode.stop()
            observer(.success(()))
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }
}



enum AudioPlayerManagerError: LocalizedError {
    case incorrectInputFormat
    case cannotConfigureConverter
    case engineStartFailure(Error)
    case cannotCreateOutputBuffer
    case converterFailure(Error?)
}

extension AVAudioFormat {
    func getTargetFrameCapacity(for buffer: AVAudioPCMBuffer) -> AVAudioFrameCount {
        AVAudioFrameCount(sampleRate) * buffer.frameLength / AVAudioFrameCount(buffer.format.sampleRate)
    }
}

extension AVAudioPCMBuffer {
    /// Длительность в секундах.
    var duration: TimeInterval {
        Double(frameLength) / format.sampleRate
    }
}

extension Array where Element == AVAudioPCMBuffer {
    var duration: TimeInterval {
        reduce(0, { $0 + $1.duration })
    }
}
