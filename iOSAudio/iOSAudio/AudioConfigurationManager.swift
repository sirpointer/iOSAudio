//
//  AudioConfigurationManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 27.04.2024.
//

import Foundation
import AVFoundation
import RxSwift

enum AudioConfigurationResult {
    case audioSessionConfigured
    case microphonePermissionDenied(MicrophonePermission)
    case failedToConfigure(Error)
}

enum MicrophonePermission {
    case undetermined
    case denied
    case granted

    fileprivate init(from recordPermission: AVAudioSession.RecordPermission) {
        switch recordPermission {
        case .undetermined: self = .undetermined
        case .denied: self = .denied
        case .granted: self = .granted
        @unknown default: self = .denied
        }
    }
}

final class AudioConfigurationManager {
    private let audioSession = AVAudioSession.sharedInstance()

    func configure() -> Single<AudioConfigurationResult> {
        Single<AudioConfigurationResult>.create { [weak self] observer in
            self?.configure { observer(.success($0)) }
            return Disposables.create()
        }
    }

    private func configure(observer: @escaping (AudioConfigurationResult) -> Void) {
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
            audioSession.requestRecordPermission { [weak audioSession] granted in
                guard let audioSession else { return }
                if granted {
                    observer(.audioSessionConfigured)
                } else {
                    observer(.microphonePermissionDenied(.init(from: audioSession.recordPermission)))
                }
            }
        } catch {
            observer(.failedToConfigure(error))
        }
    }

    private func setupInputRoute() throws {
//        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP, .allowBluetooth])
        let currentRoute: AVAudioSessionRouteDescription = audioSession.currentRoute
        if currentRoute.outputs.count != 0 {
            for portDescription in currentRoute.outputs {
                if portDescription.portType == AVAudioSession.Port.headphones || portDescription.portType == AVAudioSession.Port.bluetoothA2DP {
                    try audioSession.overrideOutputAudioPort(.none)
                } else {
                    try audioSession.overrideOutputAudioPort(.speaker)
                }
            }
        } else {
            try audioSession.overrideOutputAudioPort(.speaker)
        }

        if let availableInputs = audioSession.availableInputs {
            var microphone: AVAudioSessionPortDescription? = nil

            for inputDescription in availableInputs {
                if inputDescription.portType == .headphones || inputDescription.portType == .bluetoothHFP {
                    print("[AudioEngine]: \(inputDescription.portName) (\(inputDescription.portType.rawValue)) is selected as the input source. ")
                    microphone = inputDescription
                    break
                }
            }

            if let microphone {
                try audioSession.setPreferredInput(microphone)
            }
        }

        print("[AudioEngine]: Audio session is active.")
    }
}
