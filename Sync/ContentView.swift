import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Sync")
                .font(.system(size: 36, weight: .bold))
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Divider()

            switch model.mode {
            case .idle:
                idleControls
            case .host:
                hostControls
            case .peer:
                peerControls
            }
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 300)
    }

    private var idleControls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.startHost() }
            } label: {
                Label("Host Audio", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { await model.startPeer() }
            } label: {
                Label("Join a Host", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
    }

    private var hostControls: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "wave.3.right")
                Text("Peers connected: \(model.peerCount)")
                    .font(.headline)
            }
            Text("Play anything (Apple Music, Spotify, browser…). Peers stream it in sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                model.toggleMute()
            } label: {
                Label(model.isMuted ? "Unmute This Mac" : "Mute This Mac",
                      systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }

            Button("Stop", role: .destructive) {
                Task { await model.stop() }
            }
            .padding(.top, 4)
        }
    }

    private var peerControls: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: model.clockSynced ? "checkmark.circle.fill" : "clock.arrow.2.circlepath")
                    .foregroundStyle(model.clockSynced ? .green : .orange)
                Text(model.clockSynced ? "Synced" : "Calibrating clock…")
                    .font(.headline)
            }
            if model.clockSynced {
                VStack(spacing: 2) {
                    Text(String(format: "RTT %.2f ms · offset %.2f ms",
                                model.clockRTT * 1000, model.clockOffset * 1000))
                    Text(String(format: "Output latency %.2f ms (compensated)",
                                model.outputLatency * 1000))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button("Stop", role: .destructive) {
                Task { await model.stop() }
            }
            .padding(.top, 4)
        }
    }
}
