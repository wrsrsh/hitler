import Foundation

/// Thin AppleScript wrapper for the system output mute state.  Uses Standard
/// Additions (`set volume`) — no Automation/TCC permission needed, no entitlement.
enum SystemVolume {
    static func mute() {
        run("set volume with output muted")
    }

    static func unmute() {
        run("set volume without output muted")
    }

    static func isMuted() -> Bool {
        guard let out = runReading("output muted of (get volume settings)") else {
            return false
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - private

    private static func run(_ script: String) {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // Best-effort; ignore failures.
        }
    }

    private static func runReading(_ script: String) -> String? {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
