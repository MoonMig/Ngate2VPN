import Foundation
import Network
import CFNetwork

/// ngateconsoleclient reaches gateways through the *system* proxy. When that
/// proxy (Shadowrocket etc.) is down, or answers CONNECT with an error, every
/// attempt dies with a cryptic socket error. This probes the same path the
/// client will take so the journal can name the real culprit.
enum ProxyPreflight {

    struct Proxy: Equatable, Sendable {
        let host: String
        let port: Int
        var label: String { "\(host):\(port)" }
    }

    enum Outcome: Equatable, Sendable {
        case ok(Proxy)
        case unreachable(Proxy)
        case rejected(Proxy, status: Int)
        case noResponse(Proxy)
    }

    /// The HTTP(S) proxy macOS would use for `url`, honouring the bypass list;
    /// nil when the gateway is contacted directly (or via SOCKS/PAC, which we
    /// don't probe).
    static func proxy(for url: URL) -> Proxy? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let list = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for entry in list {
            let type = entry[kCFProxyTypeKey as String] as? String
            guard type == (kCFProxyTypeHTTPS as String) || type == (kCFProxyTypeHTTP as String),
                  let host = entry[kCFProxyHostNameKey as String] as? String,
                  let port = entry[kCFProxyPortNumberKey as String] as? Int
            else { continue }
            return Proxy(host: host, port: port)
        }
        return nil
    }

    /// Asks the proxy to open a tunnel to the gateway and reports how it answered.
    static func probe(_ proxy: Proxy, targetHost: String, targetPort: Int, timeout: TimeInterval = 6) async -> Outcome {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else { return .unreachable(proxy) }
        return await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(proxy.host), port: port, using: .tcp)
            gate.cleanup = { connection.cancel() }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if error != nil { gate.finish(.noResponse(proxy)) }
                    })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        gate.finish(parse(data, proxy: proxy))
                    }
                case .waiting, .failed:
                    // .waiting is how a refused connection to the proxy shows up.
                    gate.finish(.unreachable(proxy))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.finish(.noResponse(proxy))
            }
        }
    }

    /// `HTTP/1.1 200 Connection established` → .ok, any other status → .rejected.
    static func parse(_ data: Data?, proxy: Proxy) -> Outcome {
        guard let data, let text = String(data: data, encoding: .utf8) else { return .noResponse(proxy) }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            return .noResponse(proxy)
        }
        return status == 200 ? .ok(proxy) : .rejected(proxy, status: status)
    }

    /// Journal warning for a failed probe; nil when the proxy is fine.
    static func warning(for outcome: Outcome, host: String) -> String? {
        let hint = "Tunnels to this gateway will likely fail. Check the proxy app, or add \(host) to its bypass list."
        switch outcome {
        case .ok:
            return nil
        case .unreachable(let p):
            return "System proxy \(p.label) is not accepting connections. \(hint)"
        case .rejected(let p, let status):
            return "System proxy \(p.label) refused to tunnel to \(host) (HTTP \(status)). \(hint)"
        case .noResponse(let p):
            return "System proxy \(p.label) did not answer a CONNECT to \(host). \(hint)"
        }
    }
}

/// Resumes a continuation exactly once, however many callbacks race to finish.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProxyPreflight.Outcome, Never>?
    var cleanup: (() -> Void)?

    init(_ continuation: CheckedContinuation<ProxyPreflight.Outcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: ProxyPreflight.Outcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        cleanup?()
        pending.resume(returning: outcome)
    }
}
