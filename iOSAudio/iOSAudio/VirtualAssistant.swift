//
//  VirtualAssistant.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 27.04.2024.
//

import SwiftUI
import RxSwift

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
                } else {
                    vm.configuredSuccessfuly = false
                }
                vm.configurationStatus = "\(result)"
                vm.configurationIsInProgress = false
            }
            .disposed(by: disposeBag)
    }

    func startRecording() {
        do {
            try recorderManager.start()
            recordingInProgress = true
        } catch {
            print(error.localizedDescription)
            recordingInProgress = false
        }
    }

    func finishRecording() {
        recorderManager.stop()
        recordingInProgress = false
    }

    func play() {
        playerManager.play()
    }
}

#Preview {
    VirtualAssistant()
}
