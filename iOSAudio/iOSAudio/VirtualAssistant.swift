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
        VStack {
            Text(vm.configurationStatus)
                .font(.largeTitle)
                .padding()

            Button(action: {
                vm.configure()
            }, label: {
                Text("Configure AudioSession")
            })
        }
    }
}

final class VirtualAssistantVM: ObservableObject {
    private var disposeBag = DisposeBag()
    private let configurationManager = AudioConfigurationManager()

    @Published var configurationStatus = "None"

    func configure() {
        configurationManager.configure()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(with: self) { vm, result in
                switch result {
                case .audioSessionConfigured:
                    vm.configurationStatus = "Configured!"
                case let .microphonePermissionDenied(status):
                    vm.configurationStatus = "\(status)"
                case let .failedToConfigure(error):
                    vm.configurationStatus = error.localizedDescription
                }
            }
            .disposed(by: disposeBag)
    }
}

#Preview {
    VirtualAssistant()
}
