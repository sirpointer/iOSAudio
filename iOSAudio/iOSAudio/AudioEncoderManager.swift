//
//  AudioEncoderManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 17.05.2024.
//

import Foundation
import AVFoundation
import RxSwift

enum AudioEncoderManagerError: LocalizedError {
    case noData
    case cannotFindDocumentDirectory
    case cannotWriteBuffer(URL, Error)
    case cannotReadFlacFile(URL)
}

final class AudioEncoderManager {
    let sampleRate: Double
    let numberOfChannels: UInt32

    private let encoderQueue = DispatchQueue(label: "audioEncoderManager")

    init(sampleRate: Double, numberOfChannels: UInt32) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
    }

    // MARK: Encode
    func encodeToFlac(_ buffers: [AVAudioPCMBuffer]) -> Single<Data> {
        Single.create { [weak self] observer in
            self?.encodeToFlac(buffers, callback: observer)
            return Disposables.create()
        }
    }

    func encodeToFlac(_ buffers: [AVAudioPCMBuffer], callback: @escaping (Result<Data, Error>) -> Void) {
        encoderQueue.async { [weak self] in
            self?.encodeBuffersToFlac(buffers, observer: callback)
        }
    }

    private func encodeBuffersToFlac(_ buffers: [AVAudioPCMBuffer], observer: (Result<Data, Error>) -> Void) {
        guard !buffers.isEmpty else {
            observer(.failure(AudioEncoderManagerError.noData))
            return
        }

        do {
            let recordingId = UUID().uuidString
            let tempFileURL = try tempFileUrl(with: recordingId)
            try createFlacFile(with: buffers, at: tempFileURL)
            let flacData = try readFlacFileData(at: tempFileURL)
            try? removeFile(at: tempFileURL)
            observer(.success(flacData))
        } catch {
            observer(.failure(error))
        }
    }

    private func createFlacFile(with buffers: [AVAudioPCMBuffer], at url: URL) throws {
        let formatSettings: [String: Any] = [
            AVFormatIDKey: Constants.flacFormatId,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: numberOfChannels,
            AVLinearPCMBitDepthKey: Constants.pcmBitDepthKey
        ]

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: formatSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        for buffer in buffers {
            do {
                try audioFile.write(from: buffer)
            } catch {
                throw AudioEncoderManagerError.cannotWriteBuffer(url, error)
            }
        }
    }

    private func readFlacFileData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AudioEncoderManagerError.cannotReadFlacFile(url)
        }
    }

    private func removeFile(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private func tempFileUrl(with id: String) throws -> URL {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AudioEncoderManagerError.cannotFindDocumentDirectory
        }
        return documentDirectory.appendingPathComponent("encode_\(id).flac")
    }
}

private extension AudioEncoderManager {
    enum Constants {
        static let pcmBitDepthKey: Int = 16
        static let flacFormatId: AudioFormatID = kAudioFormatFLAC
    }
}
