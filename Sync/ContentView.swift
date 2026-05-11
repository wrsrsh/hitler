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
        .frame(minWidth: 380, minHeight: 280)
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

            Toggle("Host plays through its own speakers (needs muted source)", isOn: $model.hostPlaysLocally)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private var hostControls: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "wave.3.right")
                Text("Peers connected: \(model.peerCount)")
                    .font(.headline)
            }
            Text("Play anything (Apple Music, Spotify, YouTube...). All connected Macs stream in sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                Text(model.clockSynced
                     ? String(format: "Synced — offset %.2f ms", model.clockOffset * 1000)
                     : "Calibrating clock...")
                    .font(.headline)
            }
            Button("Stop", role: .destructive) {
                Task { await model.stop() }
            }
            .padding(.top, 4)
        }
    }
}

