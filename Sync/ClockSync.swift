import Foundation

/// NTP-style one-way offset estimator.
/// hostTime ≈ localTime + offset
final class ClockSync {
    private(set) var offset: Double = 0
    private var bestRTT: Double = .infinity
    var hasSync: Bool { bestRTT.isFinite }

    /// t1: peer-clock send time of ping
    /// t2recv: host-clock receive time
    /// t2send: host-clock send time of pong
    /// t3: peer-clock receive time of pong
    func record(t1: Double, t2recv: Double, t2send: Double, t3: Double) {
        let rtt = (t3 - t1) - (t2send - t2recv)
        guard rtt >= 0, rtt < bestRTT else { return }
        bestRTT = rtt
        offset = ((t2recv - t1) + (t2send - t3)) / 2
    }

    func hostToLocal(_ hostTime: Double) -> Double {
        hostTime - offset
    }
}
