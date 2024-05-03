//
//  AudioRecorderManager.swift
//  iOSAudio
//
//  Created by Novikov Nikita on 02.05.2024.
//

import Foundation
import AVFoundation

final class AudioRecorderManager: NSObject {
//    private let engine = AVAudioEngine()
//    private let converter = AVAudioConverter()
    private var recorder: AVAudioRecorder?

    private let audioSession = AVAudioSession.sharedInstance()

    let sampleRate: Int
    let numberOfChannels: Int
    let audioQuality: Int

    init(sampleRate: Int = 16000, numberOfChannels: Int = 1, audioQuality: Int = 16) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.audioQuality = audioQuality
    }

    func start() throws {
        let recordingURL = URL.recordingURL
        print(recordingURL.absoluteString)

        //        let settings = [
        //            AVFormatIDKey: Int(kAudioFormatFLAC),
        ////            AVSampleRateKey: sampleRate,
        ////            AVNumberOfChannelsKey: numberOfChannels,
        ////            AVEncoderAudioQualityKey: audioQuality
        //        ]

        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        //        try audioSession.setActive(true)

        let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        recorder.deleteRecording()
        recorder.delegate = self
        recorder.prepareToRecord()
        let value = recorder.record()
        print("Record - \(value)")
        self.recorder = recorder
        //        recorder.record(forDuration: 0.1)
    }

    func stop() {
        recorder?.stop()
//        try? audioSession.setActive(false)
        recorder = nil
    }
}

extension AudioRecorderManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let recordedData = try? Data(contentsOf: .recordingURL)
        print(recordedData?.count ?? 0)

        print("Recording finished \(flag)")
        print("")
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Recording error \(error?.localizedDescription ?? "")")
        print("")
    }
}

extension URL {
    static var recordingURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let whistleURL = paths[0].appendingPathComponent("tempRecording.flac")
        return whistleURL
    }
}
