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
    private var engine: AVAudioEngine
    private var playerNode = AVAudioPlayerNode()
    private var converter = AVAudioConverter()

    private let playerQueue = DispatchQueue(label: "audioPlayerManager")

    private let outputBus: AVAudioNodeBus = 0

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat

    init(sampleRate: Double, numberOfChannels: UInt32, commonFormat: AVAudioCommonFormat, engine: AVAudioEngine) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
        self.engine = engine
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
            self?.setupPlayer(observer)
            return Disposables.create()
        }
    }

    func setupPlayer(_ callback: @escaping (Result<Void, Error>) -> Void) {
        AudioConfigurationManager.configurationQueue.async { [weak self] in
            do {
                try self?.configurePlayer()
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    private func configurePlayer() throws {
        guard let inputFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: true) else {
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
            self?.play(buffers: buffers, callback: observer)
            return Disposables.create()
        }
    }

    func play(buffers: [AVAudioPCMBuffer], callback: @escaping (Result<Void, Error>) -> Void) {
        playerQueue.async { [weak self] in
            guard let self else { return }
            let buffers = buffers.compactMap { self.convertBuffer($0) }
            scheduleBuffers(buffers: buffers, observer: callback)
            playerNode.play()
        }
    }

    private func scheduleBuffers(buffers: [AVAudioPCMBuffer], observer: @escaping (Result<Void, Error>) -> Void) {
        for (index, buffer) in buffers.enumerated() {
            let isLast = index == buffers.count - 1
            let callback = isLast ? { [weak self] in
                observer(.success(()))
                self?.playerQueue.async { [weak self] in
                    self?.playerNode.stop()
                }
            } : nil
            playerNode.scheduleBuffer(buffer) { callback?() }
        }
    }

    func stop() -> Single<Void> {
        Single.create { [weak self] observer in
            self?.stop { observer(.success(())) }
            return Disposables.create()
        }
    }

    func stop(_ callback: @escaping () -> Void) {
        playerQueue.async { [weak self] in
            self?.playerNode.stop()
            callback()
        }
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
