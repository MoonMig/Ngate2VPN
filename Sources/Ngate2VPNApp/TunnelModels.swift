import Foundation
import SwiftUI

enum SystemLogLevel: String {
    case info = "Info"
    case warning = "Warning"
    case error = "Error"
    case critical = "Critical"
}

enum TunnelAuthMethod: String, Codable, CaseIterable, Identifiable {
    case certificate, credentials
    var id: String { rawValue }
    var title: String { self == .certificate ? "Certificate" : "Login" }
}

struct TunnelConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var title, endpointURL, serialNumber, pinCode, username, password: String
    var authMethod: TunnelAuthMethod
    /// When true, the watchdog will reconnect this tunnel automatically after
    /// any unexpected disconnect (network drop, process crash), regardless of
    /// how many consecutive failures occur. Manual disconnects (via the UI)
    /// are never retried — they always leave the tunnel in .stopped.
    var autoReconnect: Bool = false
    init(id: UUID = UUID(), title: String, endpointURL: String = "", authMethod: TunnelAuthMethod = .certificate, serialNumber: String = "", pinCode: String = "", username: String = "", password: String = "", autoReconnect: Bool = false) {
        self.id = id; self.title = title; self.endpointURL = endpointURL
        self.authMethod = authMethod; self.serialNumber = serialNumber
        self.pinCode = pinCode; self.username = username; self.password = password
        self.autoReconnect = autoReconnect
    }

    // Hand-written so that fields added in later versions never make older
    // saved profiles undecodable: the synthesized decoder requires every key,
    // and a decode failure used to mean "start with no profiles at all".
    private enum CodingKeys: String, CodingKey {
        case id, title, endpointURL, serialNumber, pinCode, username, password, authMethod, autoReconnect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        endpointURL = try c.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        pinCode = try c.decodeIfPresent(String.self, forKey: .pinCode) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        authMethod = try c.decodeIfPresent(TunnelAuthMethod.self, forKey: .authMethod) ?? .certificate
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
    }
}

/// Prevents sensitive fields from appearing in debug output, logs, or crash reports.
extension TunnelConfiguration: CustomDebugStringConvertible {
    var debugDescription: String {
        "TunnelConfiguration(id: \(id), title: \(title), endpoint: \(endpointURL), auth: \(authMethod))"
    }
}

extension TunnelState {
    var title: String { switch self {
        case .stopped: return "Disconnected"
        case .starting: return "Connecting"
        case .running: return "Connected"
        case .degraded: return "Degraded"
        case .stopping: return "Disconnecting"
        case .failed: return "Failed"
    }}
    var color: Color { switch self {
        case .stopped: return Color(red: 0.34, green: 0.40, blue: 0.47)
        case .starting, .stopping: return Color(red: 0.84, green: 0.56, blue: 0.16)
        case .running: return Color(red: 0.12, green: 0.62, blue: 0.41)
        case .degraded: return Color(red: 0.89, green: 0.62, blue: 0.14)
        case .failed: return Color(red: 0.78, green: 0.24, blue: 0.20)
    }}
}

enum TunnelError: String, Codable {
    case invalidCredentials
    case certificateNotFound
    case invalidCertificateHash
    case serverCertificateNameMismatch
    case networkUnreachable
    case connectionRefused
    case gatewayUnreachable
    case invalidEndpoint
    case sessionRefreshFailed
    case startupTimeout
    case twoFactorTimeout
    case proxyFailure
    case processExited
    case launchFailed
    case unknown

    var isRetryable: Bool {
        switch self {
        case .networkUnreachable, .connectionRefused, .gatewayUnreachable, .startupTimeout, .sessionRefreshFailed,
             .twoFactorTimeout, .proxyFailure:
            return true
        case .invalidCredentials, .certificateNotFound, .invalidCertificateHash,
             .serverCertificateNameMismatch, .processExited, .launchFailed,
             .unknown, .invalidEndpoint:
            return false
        }
    }

    /// A password login the gateway turned down quickly. Its response is
    /// identical for a wrong password, a declined 2FA prompt and a temporary
    /// lock, so the text must not claim to know which.
    static let passwordLoginRejectedMessage =
        "Login rejected by the gateway. Check the password and that the second-factor prompt was approved — a declined prompt or a temporary lock looks the same."

    var message: String {
        switch self {
        case .invalidCredentials: return "Invalid credentials"
        case .certificateNotFound: return "Certificate not found"
        case .invalidCertificateHash: return "Invalid certificate hash"
        case .serverCertificateNameMismatch:
            return "The server's TLS certificate does not match this gateway's host name. The administrator needs to fix the certificate, or the URL is wrong."
        case .networkUnreachable: return "Network unreachable"
        case .connectionRefused: return "Connection refused"
        case .gatewayUnreachable: return "Gateway unreachable"
        case .invalidEndpoint: return "Invalid server URL"
        case .sessionRefreshFailed: return "VPN session was closed by server. Reconnecting…"
        case .startupTimeout: return "Startup timed out"
        case .twoFactorTimeout:
            return "Two-factor confirmation timed out. The gateway waits only ~15 s — approve the login in your authenticator app as soon as the request arrives."
        case .proxyFailure:
            return "The system proxy is not passing traffic to the gateway. Check the proxy app (or add the gateway to its bypass list)."
        case .processExited: return "Tunnel process exited unexpectedly"
        case .launchFailed: return "Tunnel failed to start"
        case .unknown: return "Unknown tunnel error"
        }
    }
}

struct TunnelRuntimeState {
    var status: TunnelState = .stopped
    var logLines: [String] = []
    var launchedAt: Date?
    var lastStateChange: Date?
    /// Set to the timestamp of the first line of output received from the process.
    /// The watchdog uses this (not launchedAt) to measure the startup timeout,
    /// so tunnels that have a silent initialisation period (DNS resolution, cert
    /// loading) get a full 30 s of actual authentication time, not 30 s from launch.
    var firstOutputAt: Date?
    var errorMessage: String?
    var lastError: TunnelError?
    var hasEstablishedConnection = false
    var isNgateReconnecting = false
    var lastWatchdogRestartAt: Date?
    var clientAddress: String?

    /// Duration of the most recent gateway login transaction of the current
    /// attempt. A password login the gateway rejects after ~15 s is a
    /// two-factor timeout, not a wrong password.
    var lastLoginTransactionSeconds: Double?

    /// How many times in a row the watchdog has had to restart this tunnel
    /// without it ever reaching `.running` and going online. Drives
    /// exponential backoff and the auto-reconnect circuit breaker.
    /// Reset to 0 on a successful "vpn online".
    var consecutiveWatchdogFailures: Int = 0

    /// Once the watchdog has tried `WatchdogPolicy.maxFailures` times
    /// and given up, this is set to true and auto-reconnect stops. The
    /// user has to take an explicit action (toggle off + on, click Connect)
    /// to clear this. Prevents infinite spam in the journal when a remote
    /// gateway is genuinely unreachable for hours.
    var watchdogPaused: Bool = false
}

struct TunnelSnapshot {
    let configuration: TunnelConfiguration
    let runtime: TunnelRuntimeState
}
