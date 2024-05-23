//
//  AudioDecoderManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 21.05.2024.
//

import Foundation
import AVFoundation
import RxSwift

enum AudioDecoderManagerError: LocalizedError {
    case writeToFileFailure(URL, Error)
    case emptyData
    case cannotFindDocumentDirectory
    case cannotCreateBuffer
    case readFileToBufferFailure(Error)
    case incorrectConverterOutputFormat
    case cannotCreateConverter
    case cannotCreatePcmBuffer
}

final class AudioDecoderManager {
    private let decoderQueue = DispatchQueue(label: "audioDecoderManager")
    private var converter: AVAudioConverter?

    let sampleRate: Double
    let numberOfChannels: UInt32
    let commonFormat: AVAudioCommonFormat

    init(sampleRate: Double, numberOfChannels: UInt32, commonFormat: AVAudioCommonFormat) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.commonFormat = commonFormat
    }

    func decodeFromFlac(_ flacData: Data) -> Single<[AVAudioPCMBuffer]> {
        Single.create { [weak self] observer in
            self?.decodeFromFlac(flacData, callback: observer)
            return Disposables.create()
        }
    }

    func decodeFromFlac(_ flacData: Data, callback: @escaping (Result<[AVAudioPCMBuffer], Error>) -> Void) {
        decoderQueue.async { [weak self] in
            guard let self else { return }
            do {
                let buffer = try decodeDataFromFlac(flacData)
                callback(.success(buffer))
            } catch {
                callback(.failure(error))
            }
        }
    }

    private func decodeDataFromFlac(_ flacData: Data) throws -> [AVAudioPCMBuffer] {
        guard !flacData.isEmpty else {
            throw AudioDecoderManagerError.emptyData
        }

        let tempFileId = UUID().uuidString
        let tempFileUrl = try tempFileUrl(with: tempFileId)
        try saveDataToFile(flacData, url: tempFileUrl)

        let buffers = try readFileToBuffers(
            url: tempFileUrl,
            targetFrameCapacity: Constants.targetFrameCapacity
        )

        var outputBuffers: [AVAudioPCMBuffer] = []
        for buffer in buffers {
            let outputBuffer = try convert(buffer)
            outputBuffers.append(outputBuffer)
        }

        try? removeFile(at: tempFileUrl)
        return outputBuffers
    }

    private func saveDataToFile(_ data: Data, url: URL) throws {
        do {
            try data.write(to: url)
        } catch {
            throw AudioDecoderManagerError.writeToFileFailure(url, error)
        }
    }

    func readFileToBuffers(url: URL, targetFrameCapacity: AVAudioFrameCount) throws -> [AVAudioPCMBuffer] {
        do {
            let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            let totalFrames = AVAudioFrameCount(audioFile.length)

            var buffers: [AVAudioPCMBuffer] = []
            var framesToRead = totalFrames

            while framesToRead > 0 {
                let currentFrameCapacity = min(framesToRead, targetFrameCapacity)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: currentFrameCapacity) else {
                    throw AudioDecoderManagerError.cannotCreateBuffer
                }
                try audioFile.read(into: buffer, frameCount: currentFrameCapacity)
                buffers.append(buffer)

                framesToRead -= currentFrameCapacity
            }

            return buffers
        } catch {
            throw AudioDecoderManagerError.readFileToBufferFailure(error)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let converter = try getConverter(inputFormat: buffer.format)
        let outputFormat = converter.outputFormat

        let targetFrameCapacity = outputFormat.getTargetFrameCapacity(for: buffer)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            throw AudioDecoderManagerError.cannotCreatePcmBuffer
        }

        try converter.convert(to: outputBuffer, from: buffer)

        return outputBuffer
    }

    private func getConverter(inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        guard let outputFormat = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: true) else {
            throw AudioDecoderManagerError.incorrectConverterOutputFormat
        }

        if let converter {
            return converter
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioDecoderManagerError.cannotCreateConverter
            }
            self.converter = converter
            return converter
        }
    }

    private func removeFile(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private func tempFileUrl(with id: String) throws -> URL {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AudioDecoderManagerError.cannotFindDocumentDirectory
        }
        return documentDirectory.appendingPathComponent("decode_\(id).flac")
    }
}

private extension AudioDecoderManager {
    enum Constants {
        static let targetFrameCapacity: AVAudioFrameCount = 2048
    }
}
