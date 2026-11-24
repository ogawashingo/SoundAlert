import Foundation
import AVFoundation

final class AudioPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private(set) var playingFilename: String?
    private(set) var isPlaying: Bool = false

    var onStateChanged: ((Bool, String?) -> Void)?
    var onError: ((String) -> Void)?

    func togglePlay(url: URL, filename: String) {
        if isPlaying && playingFilename == filename {
            stop()
            return
        }

        audioPlayer?.stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.audioPlayer = player
            self.isPlaying = true
            self.playingFilename = filename
            onStateChanged?(true, filename)
        } catch {
            self.isPlaying = false
            self.playingFilename = nil
            onError?("再生エラー: \(error.localizedDescription)")
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingFilename = nil
        onStateChanged?(false, nil)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioPlayer = nil
            self.isPlaying = false
            self.playingFilename = nil
            self.onStateChanged?(false, nil)
        }
    }
}
