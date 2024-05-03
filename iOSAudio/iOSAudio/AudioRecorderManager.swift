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
    case failure(AudioRecorderManager.AudioEngineError)
    case started
    case streaming(buffer: AVAudioPCMBuffer, time: AVAudioTime)
    case converted(data: [Float], time: Float64)
}

final class AudioRecorderManager: NSObject {

    enum AudioEngineError: Error, LocalizedError {
        case converterMissing
        case cannotCreatePcmBuffer
        case noInputChannel
        case internalError(Error)
    }

    enum EngineStatus {
        case notInitialized
        case ready
        case recording
        case paused
        case failed
    }

    var player = AVAudioPlayerNode()
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFile: AVAudioFile?

    let sampleRate: Int
    let numberOfChannels: UInt32
    let audioQuality: Int

    private let dataPublisher = PublishSubject<AudioRecorderData>()
    private func publish(_ value: AudioRecorderData) {
        dataPublisher.onNext(value)
    }

    var outputData: Observable<AudioRecorderData> { dataPublisher }
    private (set) var status: EngineStatus = .notInitialized

    private let inputBus: AVAudioNodeBus = 0
    private let outputBus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount = 1024

    private var streamingInProgress: Bool = false

    init(sampleRate: Int = 16000, numberOfChannels: Int = 1, audioQuality: Int = 16) {
        self.sampleRate = sampleRate
        self.numberOfChannels = UInt32(numberOfChannels)
        self.audioQuality = audioQuality
    }

    func setupEngine() {
        engine.reset()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: outputBus)

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, audioTime in
            self?.convert(buffer: buffer, time: audioTime.audioTimeStamp.mSampleTime)
        }
        inputNode.installTap(onBus: inputBus, bufferSize: bufferSize, format: inputFormat, block: tapBlock)
        engine.prepare()
        setupConverter(inputFormat: inputFormat)

        status = .ready
        print("[AudioEngine]: Setup finished.")
    }

    private func setupConverter(inputFormat: AVAudioFormat) {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatFLAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: numberOfChannels,
            AVEncoderAudioQualityKey: audioQuality
        ]

        if let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: false) {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

//        if let outputFormat = AVAudioFormat(settings: settings) {
//            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
//        }
    }

    private func convert(buffer: AVAudioPCMBuffer, time: Float64) {
        guard let converter else {
            status = .failed
            streamingInProgress = false
            print("[AudioEngine]: Convertor doesn't exist.")
            publish(.failure(.converterMissing))
            return
        }
        let outputFormat = converter.outputFormat

        let targetFrameCapacity = AVAudioFrameCount(outputFormat.sampleRate) * buffer.frameLength / AVAudioFrameCount(buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrameCapacity) else {
            status = .failed
            streamingInProgress = false
            print("[AudioEngine]: Cannot create AVAudioPCMBuffer.")
            publish(.failure(.cannotCreatePcmBuffer))
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { [weak buffer] _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        switch status {
        case .haveData:
            publish(.streaming(buffer: buffer, time: AVAudioTime()))
            let arraySize = Int(buffer.frameLength)
            guard let start = convertedBuffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: start, count: arraySize))
            if !streamingInProgress {
                streamingInProgress = true
                publish(.started)
            }
            publish(.converted(data: samples, time: time))
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
    }

    func start() {
        guard engine.inputNode.inputFormat(forBus: inputBus).channelCount > 0 else {
            print("[AudioEngine]: No input is available.")
            streamingInProgress = false
            publish(.failure(.noInputChannel))
            status = .failed
            return
        }

        do {
            try engine.start()
            status = .recording
        } catch {
            streamingInProgress = false
            publish(.failure(.internalError(error)))
            print("[AudioEngine]: \(error.localizedDescription)")
            return
        }

        print("[AudioEngine]: Started tapping microphone.")
    }

    func stop() { 
        engine.stop()
//        outputFile = nil
        engine.reset()
        engine.inputNode.removeTap(onBus: inputBus)
        setupEngine()
    }
}

extension AudioRecorderManager {
    func writePCMBuffer(buffer: AVAudioPCMBuffer, output: URL) {
        let settings: [String: Any] = [
            AVFormatIDKey: buffer.format.settings[AVFormatIDKey] ?? kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: buffer.format.settings[AVNumberOfChannelsKey] ?? 1,
            AVSampleRateKey: buffer.format.settings[AVSampleRateKey] ?? sampleRate,
            AVLinearPCMBitDepthKey: buffer.format.settings[AVLinearPCMBitDepthKey] ?? 16
        ]

        do {
            if outputFile == nil {
                outputFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                print("[AudioEngine]: Audio file created.")
            }
            try outputFile?.write(from: buffer)
            print("[AudioEngine]: Writing buffer into the file...")
        } catch {
            print("[AudioEngine]: Failed to write into the file.")
        }
    }
}

extension URL {
    static var recordingURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let whistleURL = paths[0].appendingPathComponent("tempRecording.flac")
        return whistleURL
    }
}
