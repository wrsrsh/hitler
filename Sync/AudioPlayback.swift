import Foundation
import AVFoundation

final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var configured = false

    func ensureStarted(sampleRate: Double, channels: AVAudioChannelCount) throws {
        if configured { return }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: channels,
                                      interleaved: false) else {
            throw NSError(domain: "AudioPlayback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad AVAudioFormat"])
        }
        format = fmt
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        try engine.start()
        player.play()
        configured = true
    }

    /// Schedule an interleaved-float32 audio chunk at an absolute local-clock time.
    /// If `presentationLocalTime` is already in the past, the buffer plays immediately.
    func schedule(interleavedSamples samples: UnsafePointer<Float>,
                  frameCount: AVAudioFrameCount,
                  channels: Int,
                  presentationLocalTime: Double) {
        guard let fmt = format,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        guard let dst = buf.floatChannelData else { return }
        let outChannels = min(channels, Int(fmt.channelCount))
        for f in 0..<Int(frameCount) {
            for c in 0..<outChannels {
                dst[c][f] = samples[f * channels + c]
            }
        }
        let hostTime = AVAudioTime.hostTime(forSeconds: presentationLocalTime)
        let when = AVAudioTime(hostTime: hostTime)
        player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
        configured = false
    }
}
