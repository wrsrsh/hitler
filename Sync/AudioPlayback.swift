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
///
/// To make peers actually emit sound at the same instant, each device measures
/// its own output latency and shifts the player's render time *earlier* by that
/// amount.  Different Macs have different audio-chain latencies (built-in vs.
/// Bluetooth, sample-rate conversion, etc.), and the diff is the echo gap.
final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var configured = false
    private var startScheduled = false
    private(set) var outputLatency: Double = 0

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
        // Only valid after the engine has actually started.  Clamp to a sane
        // range; some devices return 0 (no compensation) and we don't want a
        // bogus huge value to push us absurdly far into the past.
        let raw = engine.outputNode.presentationLatency
        outputLatency = min(max(raw, 0), 0.5)
        configured = true
    }

    /// Append one chunk to the playback queue.  If this is the first chunk
    /// after configuration, the player is scheduled to start such that the
    /// speakers physically emit the first sample at `startAt` (in local-clock
    /// seconds).  `outputLatency` is subtracted from the engine render time
    /// so peers with different audio chains still emit at the same instant.
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

        if !startScheduled, let wallTime = presentationLocalTime {
            startScheduled = true
            let renderTime = wallTime - outputLatency
            let now = CACurrentMediaTime()
            if renderTime - now < 0.005 {
                player.play()
            } else {
                let ht = AVAudioTime.hostTime(forSeconds: renderTime)
                player.play(at: AVAudioTime(hostTime: ht))
            }
        }
    }

    func stop() {
        if configured {
            player.stop()
            engine.stop()
            engine.detach(player)
        }
        configured = false
        startScheduled = false
        outputLatency = 0
        format = nil
    }
}
