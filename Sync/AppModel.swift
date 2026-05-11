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
    @Published var clockSynced: Bool = false
    @Published var hostPlaysLocally: Bool = false

    private let capture = AudioCapture()
    private let playback = AudioPlayback()
    private let host = NetworkHost()
    private let peer = NetworkPeer()
    private let clock = ClockSync()

    /// How far in the future to schedule each audio chunk. Larger = more network jitter
    /// tolerance, more startup latency. 250 ms is comfortable on a typical Wi-Fi LAN.
    private let bufferDelay: Double = 0.25

    private var pingTimer: Timer?

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
            if hostPlaysLocally {
                try playback.ensureStarted(sampleRate: 48_000, channels: 2)
            }
            mode = .host
            status = hostPlaysLocally
                ? "Hosting — playing locally and streaming to peers"
                : "Hosting — streaming to peers (your own speakers play live)"
        } catch {
            status = "Host failed: \(error.localizedDescription)"
        }
    }

    func startPeer() async {
        do {
            try playback.ensureStarted(sampleRate: 48_000, channels: 2)
            peer.start()
            mode = .peer
            startPinging()
        } catch {
            status = "Peer failed: \(error.localizedDescription)"
        }
    }

    func stop() async {
        pingTimer?.invalidate()
        pingTimer = nil
        await capture.stop()
        host.stop()
        peer.stop()
        playback.stop()
        clockSynced = false
        clockOffset = 0
        peerCount = 0
        mode = .idle
        status = "Idle"
    }

    // MARK: - Host: capture → encode → broadcast → (optionally) local schedule

    private func handleCaptured(_ buf: AVAudioPCMBuffer) {
        let sampleRate = buf.format.sampleRate
        let channels = Int(buf.format.channelCount)
        let frameCount = Int(buf.frameLength)
        guard frameCount > 0, channels > 0, let cd = buf.floatChannelData else { return }

        // Tag with a future host-clock time. Host is its own reference, so
        // "host time" == "local time" on the host.
        let presentationTime = CACurrentMediaTime() + bufferDelay

        // Interleave the non-interleaved capture buffer.
        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        interleaved.withUnsafeMutableBufferPointer { dst in
            for f in 0..<frameCount {
                for c in 0..<channels {
                    dst[f * channels + c] = cd[c][f]
                }
            }
        }

        // Build the wire frame.
        var w = BinaryWriter()
        w.writeF64LE(presentationTime)
        w.writeU32LE(UInt32(sampleRate))
        w.writeU16LE(UInt16(channels))
        w.writeU32LE(UInt32(frameCount))
        interleaved.withUnsafeBytes { w.writeBytes($0) }
        let frame = Frame.encode(type: .audio, payload: w.data)
        host.broadcast(frame)

        // Optional: schedule on host's own engine so the host is one of the speakers.
        if hostPlaysLocally {
            interleaved.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                playback.schedule(
                    interleavedSamples: base,
                    frameCount: AVAudioFrameCount(frameCount),
                    channels: channels,
                    presentationLocalTime: presentationTime
                )
            }
        }
    }

    // MARK: - Peer: clock sync + audio frame scheduling

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
            clockSynced = clock.hasSync
            if clockSynced {
                status = String(format: "Synced — offset %.2f ms", clockOffset * 1000)
            }

        case .audio:
            let p = frame.payload
            guard p.count >= 18 else { return }
            let presentationHost = p.readF64LE(at: 0)
            let sampleRate = Double(p.readU32LE(at: 8))
            let channels = Int(p.readU16LE(at: 12))
            let frameCount = Int(p.readU32LE(at: 14))
            let samplesStart = 18
            let sampleBytes = frameCount * channels * MemoryLayout<Float>.size
            guard p.count >= samplesStart + sampleBytes else { return }

            try? playback.ensureStarted(sampleRate: sampleRate,
                                        channels: AVAudioChannelCount(channels))
            let local = clock.hostToLocal(presentationHost)
            p.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                    .advanced(by: samplesStart)
                    .assumingMemoryBound(to: Float.self)
                playback.schedule(
                    interleavedSamples: base,
                    frameCount: AVAudioFrameCount(frameCount),
                    channels: channels,
                    presentationLocalTime: local
                )
            }

        default:
            break
        }
    }

    private func startPinging() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
