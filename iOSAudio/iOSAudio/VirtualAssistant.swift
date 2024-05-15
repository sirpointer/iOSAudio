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
        VStack(spacing: 20) {
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
            .padding()

            Button("Play record", action: vm.play)
                .padding()

            Button("Clear buffer", action: vm.clearBuffer)
                .padding()
        }
    }
}

struct Buffer: Identifiable, Comparable {
    let id = UUID()
    let buffer: AVAudioPCMBuffer
    let timestamp = Date()

    static func < (lhs: Buffer, rhs: Buffer) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}

final class VirtualAssistantVM: ObservableObject {
    private var disposeBag = DisposeBag()

    private let sampleRate: Double = 16000
    private let numberOfChannels: UInt32 = 1
    private let commonFormat: AVAudioCommonFormat = .pcmFormatInt16

    private let audioConfigurationManager = AudioConfigurationManager()
    private lazy var recorderManager = AudioRecorderManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        commonFormat: commonFormat,
        targetChunkDuration: 0.6
    )

    private lazy var playerManager = AudioPlayerManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        commonFormat: commonFormat
    )

    private var outputFile: AVAudioFile?

    private var buffers: [AVAudioPCMBuffer] = []

    @Published var configurationIsInProgress = true
    @Published var configuredSuccessfuly = false
    @Published var recordingInProgress = false
    var status = ""

    func configure() {
        audioConfigurationManager.configure()
            .subscribe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(with: self) { vm, result in
                vm.audioConfigurationFinished(with: result)
            }
            .disposed(by: disposeBag)
    }

    private func audioConfigurationFinished(with result: AudioConfigurationResult) {
        if case .audioSessionConfigured = result {
            configuredSuccessfuly = true
            setupEngines()
        } else {
            configuredSuccessfuly = false
        }
        status = "\(result)"
        configurationIsInProgress = false
    }

    private func setupEngines() {
        do {
            try recorderManager.setupEngine()
            try playerManager.configureEngine()
            subscribeOnRecorder()
        } catch {
            status = error.localizedDescription
        }
    }

    private func subscribeOnRecorder() {
        recorderManager.outputData
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(with: self) { vm, data in
                switch data {
                case let .soundCaptured(buffers):
                    vm.buffers.append(contentsOf: buffers)
                    print("Added to buffer")
                default:
                    break
                }
            }.disposed(by: disposeBag)
    }

    func startRecording() {
        buffers.removeAll()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.recorderManager.start()
        }
        recordingInProgress = true
    }

    func finishRecording() {
        do {
            try recorderManager.stop()
            recordingInProgress = false
        } catch {
            self.status = "\(error.localizedDescription)"
            recordingInProgress = false
        }
    }

    func play() {
        playerManager.play(buffers)
            .subscribe(on: SerialDispatchQueueScheduler(qos: .userInitiated))
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(with: self) { vm, _ in
                vm.status = "Playing finished"
            } onFailure: { vm, error in
                vm.status = error.localizedDescription
            }
            .disposed(by: disposeBag)
    }

    func clearBuffer() {
        buffers.removeAll()
    }
}

#Preview {
    VirtualAssistant()
}
