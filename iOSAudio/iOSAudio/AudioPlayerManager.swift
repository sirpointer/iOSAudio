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
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var converter = AVAudioConverter()

    private let outputBus: AVAudioNodeBus = 0

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat

    init(sampleRate: Int = 16000, numberOfChannels: UInt32 = 1, commonFormat: AVAudioCommonFormat = .pcmFormatInt16) {
        self.sampleRate = Double(sampleRate)
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
    }

    func configureEngine() throws {
        playerNode.stop()
        engine.stop()
        playerNode = AVAudioPlayerNode()
        engine = AVAudioEngine()

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
        let targetFrameCapacity = AVAudioFrameCount(outputFormat.sampleRate) * buffer.frameLength / AVAudioFrameCount(buffer.format.sampleRate)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            observer(.failure(AudioPlayerManagerError.cannotCreateOutputBuffer))
            return
        }

        converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        playerNode.scheduleBuffer(outputBuffer) {
            observer(.success(()))
        }
        
        playerNode.play()
    }
}

enum AudioPlayerManagerError: LocalizedError {
    case incorrectInputFormat
    case cannotConfigureConverter
    case engineStartFailure(Error)
    case cannotCreateOutputBuffer
}
