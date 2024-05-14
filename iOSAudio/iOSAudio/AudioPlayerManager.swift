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

    private let outputBus: AVAudioNodeBus = 0

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat

    init(sampleRate: Double = 16000, numberOfChannels: UInt32 = 1, commonFormat: AVAudioCommonFormat = .pcmFormatInt16) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
    }

    func configureEngine() throws {
        playerNode.stop()
        engine.reset()
        playerNode = AVAudioPlayerNode()

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

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioPlayerManagerError.engineStartFailure(error)
        }
    }

    func play(_ buffer: AVAudioPCMBuffer) -> Single<Void> {
        Single.create { [weak self] observer in
            self?.playBuffer(buffer, observer: observer)
            return Disposables.create()
        }
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer, observer: @escaping (Result<Void, Error>) -> Void) {
        let outputFormat = converter.outputFormat

        let targetFrameCapacity = outputFormat.getTargetFrameCapacity(for: buffer)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            observer(.failure(AudioPlayerManagerError.cannotCreateOutputBuffer))
            return
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData:
            playerNode.scheduleBuffer(outputBuffer) {
                observer(.success(()))
            }
            playerNode.play()
        case .error:
            observer(.failure(AudioPlayerManagerError.converterFailure(error)))
        default:
            break
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
