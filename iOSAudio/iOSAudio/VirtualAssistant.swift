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
    private let recorderManager = AudioRecorderManager()
    private let playerManager = AudioPlayerManager()

    @Published var configurationIsInProgress = true
    @Published var configuredSuccessfuly = false
    @Published var recordingInProgress = false
    var configurationStatus = ""

    func configure() {
        configurationManager.configure()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(with: self) { vm, result in
                if case .audioSessionConfigured = result {
                    vm.configuredSuccessfuly = true
                    vm.recorderManager.setupEngine()
                    vm.subscribeOnRecorder()
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
                case let .streaming(buffer, time):
                    let filePath = FileManagerHelper.getFileURL(for: FileManagerHelper.filename)
                    vm.recorderManager.writePCMBuffer(buffer: buffer, output: filePath)
                case let .converted(data, time):
                    break
                default:
                    break
                }
            }.disposed(by: disposeBag)
    }

    func startRecording() {
        FileManagerHelper.removeFile(from: .recordingURL)
        recorderManager.start()
        recordingInProgress = true
    }

    func finishRecording() {
        recorderManager.stop()
        recordingInProgress = false
    }

    func play() {
        playerManager.play()
    }
}

private extension VirtualAssistantVM {
    func audioEngineStreaming(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        recorderManager.writePCMBuffer(buffer: buffer, output: .recordingURL)
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

    struct FileManagerHelper {
        static let filename = "audio.wav"

        static func getDocumentsDirectory() -> URL {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            return paths[0]
        }

        static func getFileURL(for fileName: String) -> URL {
            let path = getDocumentsDirectory().appendingPathComponent(fileName)
            return path as URL
        }

        static func removeFile(from url: URL) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

#Preview {
    VirtualAssistant()
}
