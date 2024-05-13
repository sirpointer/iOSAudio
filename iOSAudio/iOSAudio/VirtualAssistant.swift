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
    private let configurationManager = AudioConfigurationManager()

    private let sampleRate: Int = 16000
    private let numberOfChannels: UInt32 = 1
    private let audioFormat: AVAudioCommonFormat = .pcmFormatInt16

    private lazy var recorderManager = AudioRecorderManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        audioFormat: audioFormat
    )

    private lazy var playerManager = AudioPlayerManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        audioFormat: audioFormat
    )

    private var outputFile: AVAudioFile?

    private var buffers: [Buffer] = []

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
        recorderManager.stop()
        recordingInProgress = false
    }

    func playBuffers(buffers: [Buffer], needConfigure: Bool = true) {
        var buffers = buffers.sorted(by: >)
        guard let firstBuffer = buffers.popLast() else { return }
        let buffer = firstBuffer.buffer
        if needConfigure {
            playerManager.configureEngine()
        }
        playerManager.play(buffer)
            .subscribe { [weak self] _ in
                self?.playBuffers(buffers: buffers, needConfigure: false)
            }.disposed(by: disposeBag)
    }

    func play() {
        playBuffers(buffers: buffers, needConfigure: true)
    }
}

#Preview {
    VirtualAssistant()
}
