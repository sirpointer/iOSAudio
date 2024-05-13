//
//  VirtualAssistant.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 27.04.2024.
//

import SwiftUI
import RxSwift
import AVFAudio

struct VirtualAssistant: View {
    @StateObject private var vm = VirtualAssistantVM()

    var body: some View {
        if vm.configurationIsInProgress {
            AssistantConfiguringView()
                .onAppear(perform: vm.configure)
        } else if !vm.configuredSuccessfuly {
            AssistantConfigurationFailedView(vm: vm)
        } else {
            AssistantView(vm: vm)
        }
    }
}

private struct AssistantConfiguringView: View {
    var body: some View {
        VStack {
            Text("Configuration is in progress")
            ProgressView()
        }
    }
}

private struct AssistantConfigurationFailedView: View {
    @ObservedObject var vm: VirtualAssistantVM

    var body: some View {
        VStack {
            Text("Configuration failed")

            Button("Try again") {
                vm.configurationIsInProgress = true
                vm.configuredSuccessfuly = false
                vm.configure()
            }
        }
    }
}

private struct AssistantView: View {
    @ObservedObject var vm: VirtualAssistantVM

    var body: some View {
        VStack {
            if vm.recordingInProgress {
                Text("Recording in progress")
            }
            
            Button(vm.recordingInProgress ? "Stop recording" : "Start recording") {
                if vm.recordingInProgress {
                    vm.finishRecording()
                } else {
                    vm.startRecording()
                }
            }

            Button("Play record", action: vm.play)
        }
    }
}

final class VirtualAssistantVM: ObservableObject {
    private var disposeBag = DisposeBag()
    private let configurationManager = AudioConfigurationManager()

    private let sampleRate: Int = 16000
    private lazy var recorderManager = AudioRecorderManager(sampleRate: sampleRate)

    private let playerManager = AudioPlayerManager()
    
    private var outputFile: AVAudioFile?

    @Published var configurationIsInProgress = true
    @Published var configuredSuccessfuly = false
    @Published var recordingInProgress = false
    var configurationStatus = ""

    func configure() {
        print(URL.recordingURL.absoluteString)
        configurationManager.configure()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(with: self) { vm, result in
                if case .audioSessionConfigured = result {
                    vm.configuredSuccessfuly = true
                    vm.recorderManager.setupEngine()
                    vm.subscribeOnRecorder()
//                    vm.playerManager.configureEngine()
                } else {
                    vm.configuredSuccessfuly = false
                }
                vm.configurationStatus = "\(result)"
                vm.configurationIsInProgress = false
            }
            .disposed(by: disposeBag)
    }

    private func subscribeOnRecorder() {
        recorderManager.outputData
            .subscribe(with: self) { vm, data in
                switch data {
                case let .soundCaptured(buffer):
                    vm.writePCMBuffer(buffer: buffer, output: .recordingURL)
                case .converted:
                    break
                default:
                    break
                }
            }.disposed(by: disposeBag)
    }

    func startRecording() {
        try? FileManager.default.removeItem(at: .recordingURL)
        recorderManager.start()
        recordingInProgress = true
    }

    func finishRecording() {
        recorderManager.stop()
        recordingInProgress = false
    }

    func play() {
        guard let fileUrl = Bundle.main.url(forResource: "Intro converted", withExtension: "wav") else {
            return
        }

        do {
            let file = try AVAudioFile(forReading: fileUrl)
            print("File read")
            let format = file.processingFormat

            let audioLengthSamples = file.length
            let audioSampleRate = format.sampleRate
            let audioLengthSeconds = Double(audioLengthSamples) / audioSampleRate

            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
            print("Buffer created")

            try file.read(into: buffer)
            print("File read into buffer")

            playerManager.configureEngine(formatt: file.processingFormat)
            playerManager.play(buffer)
                .subscribe { _ in
                    print("Done!!!!!!")
                }.disposed(by: disposeBag)

//            audioFile = file
//
//            configureEngine(with: format)
        } catch {
            print("Error reading the audio file: \(error.localizedDescription)")
        }


//        playerManager.play()
    }
}

private extension VirtualAssistantVM {
    func writePCMBuffer(buffer: AVAudioPCMBuffer, output: URL) {
        let settings: [String: Any] = [
            AVFormatIDKey: buffer.format.settings[AVFormatIDKey] ?? kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: buffer.format.settings[AVNumberOfChannelsKey] ?? 1,
            AVSampleRateKey: buffer.format.settings[AVSampleRateKey] ?? sampleRate,
            AVLinearPCMBitDepthKey: buffer.format.settings[AVLinearPCMBitDepthKey] ?? 16
        ]

        do {
            if outputFile == nil {
                outputFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
                print("[AudioEngine]: Audio file created.")
            }
            try outputFile?.write(from: buffer)
            print("[AudioEngine]: Writing buffer into the file...")
        } catch {
            print("[AudioEngine]: Failed to write into the file.")
        }
    }

    private func fileSize(fromPath url: URL) -> String? {
        let path = url.path

        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[FileAttributeKey.size],
              let fileSize = size as? UInt64 else {
            return nil
        }

        // bytes
        if fileSize < 1023 {
            return String(format: "%lu bytes", CUnsignedLong(fileSize))
        }
        // KB
        var floatSize = Float(fileSize / 1024)
        if floatSize < 1023 {
            return String(format: "%.1f KB", floatSize)
        }
        // MB
        floatSize = floatSize / 1024
        if floatSize < 1023 {
            return String(format: "%.1f MB", floatSize)
        }
        // GB
        floatSize = floatSize / 1024
        return String(format: "%.1f GB", floatSize)
    }
}

extension URL {
    static var recordingURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let whistleURL = paths[0].appendingPathComponent("tempRecording")
        return whistleURL
    }
}

#Preview {
    VirtualAssistant()
}
