import Foundation
import SwiftUI
import AVFoundation
import QuartzCore

enum Mode: String {
    case idle, host, peer
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: Mode = .idle
    @Published var status: String = "Idle"
    @Published var peerCount: Int = 0
    @Published var clockOffset: Double = 0
    @Published var clockRTT: Double = 0
    @Published var clockSynced: Bool = false
    @Published var outputLatency: Double = 0
    @Published var isMuted: Bool = false

    private let capture = AudioCapture()
    private let playback = AudioPlayback()
    private let host = NetworkHost()
    private let peer = NetworkPeer()
    private let clock = ClockSync()

    /// Wall-clock delay between a sample being captured on the host and being
    /// played on every peer.  Larger = more network jitter tolerance, more
    /// startup latency.  ~350 ms is comfortable on Wi-Fi.
    private let bufferDelay: Double = 0.35

    private var pingTimer: Timer?
    private var didMuteOnStart = false

    init() {
        host.onPeerCount = { [weak self] n in
            Task { @MainActor in self?.peerCount = n }
        }
        peer.onState = { [weak self] s in
            Task { @MainActor in self?.status = s }
        }
        peer.onFrame = { [weak self] f in
            Task { @MainActor in self?.handlePeerFrame(f) }
        }
        capture.onBuffer = { [weak self] buf in
            Task { @MainActor in self?.handleCaptured(buf) }
        }
    }

    func startHost() async {
        do {
            try host.start()
            try await capture.start()
            // Auto-mute host's own speakers so the live source doesn't echo with
            // the peers' delayed copies.  User can unmute via the button.
            SystemVolume.mute()
            didMuteOnStart = true
            isMuted = true
            mode = .host
            status = "Hosting — your Mac is muted; peers are the speakers"
        } catch {
            status = "Host failed: \(error.localizedDescription)"
        }
    }

    func startPeer() async {
        peer.start()
        mode = .peer
        startPinging()
    }

    func stop() async {
        pingTimer?.invalidate()
        pingTimer = nil
        await capture.stop()
        host.stop()
        peer.stop()
        playback.stop()
        if didMuteOnStart {
            SystemVolume.unmute()
            didMuteOnStart = false
        }
        isMuted = SystemVolume.isMuted()
        clockSynced = false
        clockOffset = 0
        peerCount = 0
        mode = .idle
        status = "Idle"
    }

    func toggleMute() {
        if isMuted {
            SystemVolume.unmute()
        } else {
            SystemVolume.mute()
        }
        isMuted = SystemVolume.isMuted()
    }

    // MARK: - Host: capture → encode → broadcast

    private func handleCaptured(_ buf: AVAudioPCMBuffer) {
        let sampleRate = buf.format.sampleRate
        let channels = Int(buf.format.channelCount)
        let frameCount = Int(buf.frameLength)
        guard frameCount > 0, channels > 0, let cd = buf.floatChannelData else { return }

        let presentationTime = CACurrentMediaTime() + bufferDelay

        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        interleaved.withUnsafeMutableBufferPointer { dst in
            for f in 0..<frameCount {
                for c in 0..<channels {
                    dst[f * channels + c] = cd[c][f]
                }
            }
        }

        var w = BinaryWriter()
        w.writeF64LE(presentationTime)
        w.writeU32LE(UInt32(sampleRate))
        w.writeU16LE(UInt16(channels))
        w.writeU32LE(UInt32(frameCount))
        interleaved.withUnsafeBytes { w.writeBytes($0) }
        let frame = Frame.encode(type: .audio, payload: w.data)
        host.broadcast(frame)
    }

    // MARK: - Peer: clock sync + queue audio

    private func handlePeerFrame(_ frame: Frame) {
        switch frame.type {
        case .pong:
            guard frame.payload.count >= 24 else { return }
            let t1 = frame.payload.readF64LE(at: 0)
            let t2recv = frame.payload.readF64LE(at: 8)
            let t2send = frame.payload.readF64LE(at: 16)
            let t3 = CACurrentMediaTime()
            clock.record(t1: t1, t2recv: t2recv, t2send: t2send, t3: t3)
            clockOffset = clock.offset
            clockRTT = clock.bestRTT
            clockSynced = clock.hasSync
            if clockSynced {
                status = String(format: "Synced — RTT %.2f ms, offset %.2f ms",
                                clockRTT * 1000, clockOffset * 1000)
            }

        case .audio:
            // Drop audio until we have at least one clock-sync sample, otherwise
            // the very first chunk's start time is unreliable and the whole
            // stream is misaligned for the entire session.
            guard clock.hasSync else { return }

            let p = frame.payload
            guard p.count >= 18 else { return }
            let presentationHost = p.readF64LE(at: 0)
            let sampleRate = Double(p.readU32LE(at: 8))
            let channels = Int(p.readU16LE(at: 12))
            let frameCount = Int(p.readU32LE(at: 14))
            let samplesStart = 18
            let sampleBytes = frameCount * channels * MemoryLayout<Float>.size
            guard p.count >= samplesStart + sampleBytes else { return }

            try? playback.ensureConfigured(sampleRate: sampleRate,
                                           channels: AVAudioChannelCount(channels))
            outputLatency = playback.outputLatency
            let local = clock.hostToLocal(presentationHost)
            p.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                    .advanced(by: samplesStart)
                    .assumingMemoryBound(to: Float.self)
                playback.enqueue(
                    interleaved: base,
                    frameCount: AVAudioFrameCount(frameCount),
                    channels: channels,
                    startAt: local
                )
            }

        default:
            break
        }
    }

    private func startPinging() {
        // Burst 20 pings in the first ~500 ms (every 25 ms) so the min-RTT
        // filter has lots of samples to pick from before the first audio chunk
        // arrives.  Most of these land in <1 ms each on a quiet LAN.
        for i in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.025) { [weak self] in
                self?.sendPing()
            }
        }
        // Then keep refining the offset.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing() }
        }
    }

    private func sendPing() {
        var w = BinaryWriter()
        w.writeF64LE(CACurrentMediaTime())
        let frame = Frame.encode(type: .ping, payload: w.data)
        peer.send(frame)
    }
}
