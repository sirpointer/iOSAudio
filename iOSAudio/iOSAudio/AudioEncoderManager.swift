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

    private let encoderQueue = DispatchQueue(label: "audioEncoderManager", qos: .default)

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
            print(tempFileURL.absoluteString)
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
            interleaved: false
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
        return documentDirectory.appendingPathComponent("temp_\(id).flac")
    }
}

private extension AudioEncoderManager {
    enum Constants {
        static let pcmBitDepthKey: Int = 16
        static let flacFormatId: AudioFormatID = kAudioFormatFLAC
    }
}


// MARK: Ниже для дебага
private extension AudioEncoderManager {
    func removeTempFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else { return }
        for file in files {
            if file.lastPathComponent.hasPrefix("temp_") && file.lastPathComponent.hasSuffix(".flac") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: Using AVAudioFile
extension AudioEncoderManager {
    /// Для теста.
    func writeFlacToFileWithAVAudioFile(buffers: [AVAudioPCMBuffer]) throws {
        try? FileManager.default.removeItem(at: .recordingAVAudioFileURL)

        guard let firstBuffer = buffers.first else { return }

        let formatSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: firstBuffer.format.sampleRate,
            AVNumberOfChannelsKey: firstBuffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16
        ]

        do {
            let audioFile = try AVAudioFile(forWriting: .recordingAVAudioFileURL, settings: formatSettings, commonFormat: .pcmFormatInt16, interleaved: false)

            print(URL.recordingAVAudioFileURL)

            for buffer in buffers {
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    print("Error writing buffer to file: \(error)")
                    throw error
                }
            }
            print("File written!")
        } catch {
            print(error.localizedDescription)
            throw error
        }
    }
}

// MARK: Using ExtAudioFileRef
extension AudioEncoderManager {
    /// Для теста.
    func writeFlacToFileWithExtAudioFileRef(buffers: [AVAudioPCMBuffer]) throws {
        try? FileManager.default.removeItem(at: .recordingExtAudioFileRefURL)

        guard let firstBuffer = buffers.first else { return }
        let outputFormatID = kAudioFormatFLAC
        let sampleRate: Double = firstBuffer.format.sampleRate
        let channels: UInt32 = firstBuffer.format.channelCount

        // Create an audio file
        guard let extAudioFile = createAudioFile(url: .recordingExtAudioFileRefURL, formatID: outputFormatID, sampleRate: sampleRate, channels: channels) else {
            fatalError("Failed to create ExtAudioFile")
        }

        let clientFormat = firstBuffer.format

        var audioStreamDesc = clientFormat.streamDescription.pointee
        let result = ExtAudioFileSetProperty(
            extAudioFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: audioStreamDesc)),
            &audioStreamDesc
        )

        guard result == noErr else {
            fatalError("Failed to set client data format: \(result)")
        }

        // Write the buffers to the FLAC file
        writeBuffersToFLAC(buffers: buffers, to: extAudioFile)

        // Close the audio file
        ExtAudioFileDispose(extAudioFile)
    }

    private func createAudioFile(url: URL, formatID: AudioFormatID, sampleRate: Double, channels: UInt32) -> ExtAudioFileRef? {
        var audioFile: ExtAudioFileRef?
        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let result = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &outputDesc, nil, AudioFileFlags.eraseFile.rawValue, &audioFile)

        guard result == noErr, let extAudioFile = audioFile else {
            print("Error creating audio file: \(result)")
            return nil
        }

        return extAudioFile
    }

    private func writeBuffersToFLAC(buffers: [AVAudioPCMBuffer], to audioFile: ExtAudioFileRef) {
        for buffer in buffers {
            guard buffer.audioBufferList.pointee.mBuffers.mData != nil else {
                print("Buffer data is nil")
                continue
            }

            let ioNumberFrames = buffer.frameLength
            let result = ExtAudioFileWrite(audioFile, ioNumberFrames, buffer.audioBufferList)

            if result != noErr {
                print("Error writing buffer to file: \(result)")
            }
        }
    }
}

private extension URL {
    static let recordingAVAudioFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordingAVAudioFile.flac")
    static let recordingExtAudioFileRefURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordingExtAudioFileRef.flac")
}
