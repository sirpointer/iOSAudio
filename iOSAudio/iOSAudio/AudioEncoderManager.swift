//
//  AudioEncoderManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 17.05.2024.
//

import Foundation
import AVFoundation
import RxSwift

final class AudioEncoderManager {
    
    private let encoderQueue = DispatchQueue(label: "audioEncoderManager", qos: .default, attributes: .concurrent)
    private lazy var scheduler = ConcurrentDispatchQueueScheduler(queue: encoderQueue)

    func encode(_ buffers: [AVAudioPCMBuffer]) -> Single<Data> {
        Single.create { observer in
            return Disposables.create()
        }
        .subscribe(on: scheduler)
    }
}

// MARK: Using AVAudioFile
extension AudioEncoderManager {
    func writeFlacToFileWithAVAudioFile(buffers: [AVAudioPCMBuffer]) throws {
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
    func writeFlacToFileWithExtAudioFileRef(buffers: [AVAudioPCMBuffer]) throws {
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

    func createAudioFile(url: URL, formatID: AudioFormatID, sampleRate: Double, channels: UInt32) -> ExtAudioFileRef? {
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

extension URL {
    static let recordingAVAudioFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordingAVAudioFile.flac")
    static let recordingExtAudioFileRefURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordingExtAudioFileRef.flac")
}
