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
    static let configurationQueue = DispatchQueue(label: "AudioConfigurationQueue")

    func configure() -> Single<AudioConfigurationResult> {
        Single<AudioConfigurationResult>.create { [weak self] observer in
            self?.configure { observer(.success($0)) }
            return Disposables.create()
        }
    }

    func configure(_ callback: @escaping (AudioConfigurationResult) -> Void) {
        Self.configurationQueue.async { [weak self] in
            self?.configureSession(callback)
        }
    }

    private func configureSession(_ callback: @escaping (AudioConfigurationResult) -> Void) {
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            audioSession.requestRecordPermission { [audioSession] granted in
                if granted {
                    callback(.audioSessionConfigured)
                } else {
                    callback(.microphonePermissionDenied(.init(from: audioSession.recordPermission)))
                }
            }
        } catch {
            callback(.failedToConfigure(error))
        }
    }
}
