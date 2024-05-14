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
        commonFormat: commonFormat
    )

    private lazy var playerManager = AudioPlayerManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        commonFormat: commonFormat
    )

    private var outputFile: AVAudioFile?

    private var buffers: [Buffer] = []

    @Published var configurationIsInProgress = true
    @Published var configuredSuccessfuly = false
    @Published var recordingInProgress = false
    var status = ""

    func configure() {
        audioConfigurationManager.configure()
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
            .subscribe(with: self) { vm, data in
                switch data {
                case let .soundCaptured(buffer):
                    vm.buffers.append(Buffer(buffer: buffer))
                default:
                    break
                }
            }.disposed(by: disposeBag)
    }

    func startRecording() {
        buffers.removeAll()
        recorderManager.start()
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
        playBuffers(buffers: buffers)
    }

    private func playBuffers(buffers: [Buffer]) {
        var buffers = buffers.sorted(by: >)
        guard let firstBuffer = buffers.popLast() else { return }

        playerManager.play(firstBuffer.buffer)
            .subscribe { [weak self] _ in
                self?.playBuffers(buffers: buffers)
            } onFailure: { [weak self] error in
                self?.status = "\(error.localizedDescription)"
            }
            .disposed(by: disposeBag)
    }
}

#Preview {
    VirtualAssistant()
}
