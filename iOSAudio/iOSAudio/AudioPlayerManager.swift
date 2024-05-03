//
//  AudioPlayerManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 02.05.2024.
//

import Foundation
import AVFoundation

final class AudioPlayerManager {
    private var player: AVAudioPlayer?

    func play() {
        do {
            print(URL.recordingURL.absoluteString)
            player = try AVAudioPlayer(contentsOf: .recordingURL)
            player?.prepareToPlay()
            player?.play()
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
