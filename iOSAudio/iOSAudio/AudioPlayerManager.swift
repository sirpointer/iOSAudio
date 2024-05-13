//
//  AudioPlayerManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 02.05.2024.
//

import Foundation
import AVFoundation
import RxSwift

final class AudioPlayerManager {

    
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()

    let sampleRate: Double
    let numberOfChannels: UInt32
    let audioFormat: AVAudioCommonFormat

    init(sampleRate: Int = 22000, numberOfChannels: UInt32 = 1, audioFormat: AVAudioCommonFormat = .pcmFormatInt16) {
        self.sampleRate = Double(sampleRate)
        self.numberOfChannels = numberOfChannels
        self.audioFormat = audioFormat
//        self.configureEngine()
    }

    func configureEngine(formatt: AVAudioFormat? = nil) {
        playerNode.stop()
        engine.stop()
        playerNode = AVAudioPlayerNode()
        engine = AVAudioEngine()
        let format = AVAudioFormat(commonFormat: audioFormat, sampleRate: sampleRate, channels: numberOfChannels, interleaved: false)
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: formatt ?? format)
        engine.prepare()
        try! engine.start()
    }

    func play(_ buffer: AVAudioPCMBuffer) -> Single<Void> {
        Single.create { [weak playerNode] observer in
            playerNode?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                observer(.success(()))
            }
            playerNode?.play()

            return Disposables.create()
        }
    }

//    func play() {
//        do {
//            print(URL.recordingURL.absoluteString)
//            player = try AVAudioPlayer(contentsOf: .recordingURL)
//            player?.prepareToPlay()
//            player?.play()
//        } catch {
//            fatalError(error.localizedDescription)
//        }
//    }
}
