import Foundation
import Network
import QuartzCore

final class NetworkHost {
    var onPeerCount: ((Int) -> Void)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let q = DispatchQueue(label: "sync.network.host")

    func start() throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: Host.current().localizedName,
                                              type: "_syncaudio._tcp")
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNew(conn)
        }
        listener.start(queue: q)
        self.listener = listener
    }

    func stop() {
        q.async {
            for c in self.connections { c.cancel() }
            self.connections.removeAll()
            self.listener?.cancel()
            self.listener = nil
            DispatchQueue.main.async { self.onPeerCount?(0) }
        }
    }

    func broadcast(_ data: Data) {
        q.async {
            for c in self.connections {
                c.send(content: data, completion: .idempotent)
            }
        }
    }

    private func handleNew(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.q.async {
                    self.connections.append(conn)
                    DispatchQueue.main.async { self.onPeerCount?(self.connections.count) }
                }
                self.readLoop(conn)
            case .failed, .cancelled:
                self.q.async {
                    self.connections.removeAll { $0 === conn }
                    DispatchQueue.main.async { self.onPeerCount?(self.connections.count) }
                }
            default:
                break
            }
        }
        conn.start(queue: q)
    }

    private func readLoop(_ conn: NWConnection) {
        FrameReader.read(from: conn, onFrame: { [weak self] frame in
            self?.handle(frame, from: conn)
        }, onError: { _ in
            // Drop connection silently; state handler will clean up.
        })
    }

    private func handle(_ frame: Frame, from conn: NWConnection) {
        switch frame.type {
        case .ping:
            guard frame.payload.count >= 8 else { return }
            let t1 = frame.payload.readF64LE(at: 0)
            let t2recv = CACurrentMediaTime()
            var w = BinaryWriter()
            w.writeF64LE(t1)
            w.writeF64LE(t2recv)
            w.writeF64LE(CACurrentMediaTime())  // t2send
            let out = Frame.encode(type: .pong, payload: w.data)
            conn.send(content: out, completion: .idempotent)
        default:
            break
        }
    }
}
