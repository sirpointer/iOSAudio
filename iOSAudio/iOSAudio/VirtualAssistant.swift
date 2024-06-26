//
//  VirtualAssistant.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 27.04.2024.
//

import SwiftUI
import RxSwift
import AVFoundation

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

            Button("Write to file", action: vm.writeToFile)
                .padding()

            List(vm.statusHistory.reversed()) { node in
                Text(node.status)
            }
        }
    }
}

final class VirtualAssistantVM: ObservableObject {
    struct HistoryNode: Identifiable {
        let id = UUID()
        let status: String

        init(_ status: String) {
            self.status = status
        }
    }

    private var disposeBag = DisposeBag()

    private let sampleRate: Double = 16000
    private let numberOfChannels: UInt32 = 1
    private let commonFormat: AVAudioCommonFormat = .pcmFormatInt16

    private lazy var engine = AVAudioEngine()
    private let audioConfigurationManager = AudioConfigurationManager()
    private lazy var recorderManager = AudioRecorderManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        commonFormat: commonFormat,
        targetChunkDuration: 1.5,
        engine: engine
    )

    private lazy var playerManager = AudioPlayerManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        commonFormat: commonFormat,
        engine: engine
    )

    private lazy var encoderManager = AudioEncoderManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels
    )

    private lazy var decoderManager = AudioDecoderManager(
        sampleRate: sampleRate,
        numberOfChannels: numberOfChannels,
        commonFormat: commonFormat
    )

    private var buffers: [Buffer] = []

    @Published var configurationIsInProgress = true
    @Published var configuredSuccessfuly = false
    @Published var recordingInProgress = false
    @Published var status = "" {
        willSet {
            statusHistory.append(.init(newValue))
        }
    }
    @Published private(set) var statusHistory: [HistoryNode] = []

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
        let setupRecorder = recorderManager.setupRecorder().asObservable()
        let configurePlayer = playerManager.setupPlayer().asObservable()

        Observable.zip(setupRecorder, configurePlayer)
            .observe(on: MainScheduler.asyncInstance)
            .asSingle()
            .subscribe { [weak self] _ in
                self?.subscribeOnRecorder()
                self?.statusHistory.append(.init("Configuration finished"))
            } onFailure: { [weak self] error in
                self?.status = error.localizedDescription
            }
            .disposed(by: disposeBag)
    }

    private func subscribeOnRecorder() {
        recorderManager.outputData
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { [weak self] data in
                guard let self else { return }
                switch data {
                case let .soundCaptured(buffers):
                    self.buffers.append(contentsOf: buffers)
                    statusHistory.append(.init("Sound captured, \(self.buffers.count), \(self.buffers.map(\.buffer).duration) sec"))
                case let .failure(error):
                    status = error.localizedDescription
                default:
                    break
                }
            }.disposed(by: disposeBag)
    }

    // MARK: Recording
    func startRecording() {
        buffers.removeAll()

        recorderManager.start()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { [weak self] _ in
                self?.recordingInProgress = true
                self?.statusHistory.append(.init("Recording started"))
            } onFailure: { [weak self] error in
                self?.recordingInProgress = false
                self?.status = error.localizedDescription
            }
            .disposed(by: disposeBag)
    }

    func finishRecording() {
        recorderManager.stop()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { [weak self] _ in
                self?.recordingInProgress = false
                self?.statusHistory.append(.init("Recording stopped"))
            } onFailure: { [weak self] error in
                self?.recordingInProgress = false
                self?.status = error.localizedDescription
            }
            .disposed(by: disposeBag)
    }

    // MARK: Playing
    func play() {
        let buffers = buffers.sorted().map(\.buffer)
        playerManager.play(buffers)
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
        statusHistory.append(.init("Buffers cleared"))
    }

    func writeToFile() {
        encoderManager.encodeToFlac(buffers.map(\.buffer))
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { [weak self] data in
                self?.dataToBuffers(data: data)
                self?.statusHistory.append(.init("Buffers converter to FLAC"))
            } onFailure: { [weak self] error in
                self?.statusHistory.append(.init(error.localizedDescription))
            }
            .disposed(by: disposeBag)
    }

    func dataToBuffers(data: Data) {
        decoderManager.decodeFromFlac(data)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { [weak self] buffers in
                self?.buffers.removeAll(keepingCapacity: true)
                self?.buffers.append(contentsOf: buffers.map({ .init(buffer: $0, time: .init()) }))
                self?.statusHistory.append(.init("FLAC converted to buffers"))
            } onFailure: { [weak self] error in
                self?.statusHistory.append(.init(error.localizedDescription))
            }
            .disposed(by: disposeBag)
    }
}

#Preview {
    VirtualAssistant()
}
