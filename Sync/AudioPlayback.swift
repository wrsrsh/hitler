import Foundation
import AVFoundation
import QuartzCore

/// Queue-and-play model.
///
/// Why not `scheduleBuffer(at: hostTime)` per chunk?  AVAudioPlayerNode treats
/// overlapping scheduled buffers as additive — and chunk presentation times
/// have microsecond-level jitter, so adjacent chunks overlap and **mix**, which
/// is a comb filter.  Result: "radio static" sound.
///
/// Instead we schedule a single start time for the whole stream and queue every
/// buffer gaplessly behind it.  Peers stay in sync because they all start at
/// the same wall-clock moment and consume samples at the same nominal rate.
final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var configured = false
    private var startScheduled = false

    func ensureConfigured(sampleRate: Double, channels: AVAudioChannelCount) throws {
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
        configured = true
    }

    /// Append one chunk to the playback queue.  If this is the first chunk,
    /// the player is scheduled to start at `startAt` (in local-clock seconds).
    func enqueue(interleaved samples: UnsafePointer<Float>,
                 frameCount: AVAudioFrameCount,
                 channels: Int,
                 startAt presentationLocalTime: Double?) {
        guard let fmt = format,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        guard let dst = buf.floatChannelData else { return }
        let outCh = min(channels, Int(fmt.channelCount))
        for f in 0..<Int(frameCount) {
            for c in 0..<outCh {
                dst[c][f] = samples[f * channels + c]
            }
        }
        player.scheduleBuffer(buf, completionHandler: nil)

        if !startScheduled, let startTime = presentationLocalTime {
            startScheduled = true
            let now = CACurrentMediaTime()
            if startTime - now < 0.005 {
                // Start time already passed (or essentially now): just play.
                player.play()
            } else {
                let ht = AVAudioTime.hostTime(forSeconds: startTime)
                player.play(at: AVAudioTime(hostTime: ht))
            }
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        configured = false
        startScheduled = false
    }
}
