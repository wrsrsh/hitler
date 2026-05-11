import Foundation
import Network

final class NetworkPeer {
    var onFrame: ((Frame) -> Void)?
    var onState: ((String) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let q = DispatchQueue(label: "sync.network.peer")

    func start() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_syncaudio._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            if self.connection == nil, let first = results.first {
                self.connect(to: first.endpoint)
            }
        }
        browser.start(queue: q)
        self.browser = browser
        DispatchQueue.main.async { self.onState?("Searching for host on Wi-Fi…") }
    }

    func send(_ data: Data) {
        q.async {
            self.connection?.send(content: data, completion: .idempotent)
        }
    }

    func stop() {
        q.async {
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
            DispatchQueue.main.async { self.onState?("Stopped") }
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.onState?("Connected — calibrating clock") }
                self.readLoop(conn)
            case .failed, .cancelled:
                self.connection = nil
                DispatchQueue.main.async { self.onState?("Disconnected") }
            default:
                break
            }
        }
        conn.start(queue: q)
        connection = conn
    }

    private func readLoop(_ conn: NWConnection) {
        FrameReader.read(from: conn, onFrame: { [weak self] frame in
            self?.onFrame?(frame)
        }, onError: { _ in })
    }
}
