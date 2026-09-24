import Foundation

/// The watchdog's decisions, as pure functions of plain values so every
/// branch can be unit-tested without processes, timers or the main actor.
/// `AppState` gathers the inputs, calls in here, and performs the side
/// effects (logging, alerts, launching).
enum WatchdogPolicy {

    // MARK: Tunables

    static let baseBackoff: TimeInterval = 5
    static let maxBackoff: TimeInterval = 15 * 60
    /// Restarts allowed without auto-reconnect before the circuit breaker trips.
    static let maxFailures = 8
    /// With auto-reconnect: ~5 h of awake time at the 15 min backoff cap.
    static let maxFailuresAutoReconnect = 24
    /// Automatic restarts after a missed 2FA confirmation. Each restart sends
    /// the user a fresh prompt, so attempts in total = this + 1.
    static let twoFactorMaxRetries = 1
    /// Pause before re-trying after a missed 2FA prompt, so the prompt the
    /// failed attempt already sent can still be approved before the next one.
    static let twoFactorRetryDelay: TimeInterval = 20

    // MARK: Restart decision

    struct Inputs: Equatable {
        var status: TunnelState
        var lastError: TunnelError?
        var autoReconnect: Bool
        var paused: Bool
        var consecutiveFailures: Int
        var lastRestartAt: Date?
        /// When the tunnel entered its current failed state.
        var lastFailureAt: Date? = nil
        var now: Date
    }

    enum PauseReason: Equatable {
        case twoFactor
        case tooManyFailures
    }

    enum Decision: Equatable {
        /// Do nothing this pass.
        case skip
        /// Stop retrying until the user acts; `failures` is the count so far.
        case pause(PauseReason, failures: Int)
        /// Start the tunnel again. `attempt` is 1-based, `limit` the cap that applies.
        case restart(attempt: Int, limit: Int, waited: TimeInterval)
    }

    /// Errors no amount of retrying can fix — the user has to edit the profile.
    static func isConfigError(_ error: TunnelError?) -> Bool {
        switch error {
        case .invalidCredentials, .certificateNotFound, .invalidCertificateHash,
             .serverCertificateNameMismatch, .invalidEndpoint:
            return true
        default:
            return false
        }
    }

    static func backoff(afterFailures failures: Int) -> TimeInterval {
        // Cap the exponent before pow blows up.
        let raw = baseBackoff * pow(2.0, Double(min(max(0, failures), 16)))
        return min(raw, maxBackoff)
    }

    static func decide(_ i: Inputs) -> Decision {
        // .stopped means the user disconnected; never reconnect.
        guard i.status != .stopped else { return .skip }

        if i.autoReconnect {
            guard !isConfigError(i.lastError) else { return .skip }
        } else {
            guard i.lastError?.isRetryable == true, i.status == .failed else { return .skip }
        }
        guard !i.paused else { return .skip }

        // A missed 2FA prompt is retried only a little: endless prompts on the
        // user's phone are worse than a failed tunnel.
        if i.lastError == .twoFactorTimeout, i.consecutiveFailures >= twoFactorMaxRetries {
            return .pause(.twoFactor, failures: i.consecutiveFailures)
        }

        if i.lastError == .twoFactorTimeout, let failedAt = i.lastFailureAt,
           i.now.timeIntervalSince(failedAt) < twoFactorRetryDelay {
            return .skip
        }

        let wait = backoff(afterFailures: i.consecutiveFailures)
        if let last = i.lastRestartAt, i.now.timeIntervalSince(last) < wait {
            return .skip
        }

        let attempt = i.consecutiveFailures + 1
        let limit = i.autoReconnect ? maxFailuresAutoReconnect : maxFailures
        if attempt > limit {
            return .pause(.tooManyFailures, failures: i.consecutiveFailures)
        }
        return .restart(attempt: attempt, limit: limit, waited: wait)
    }

    // MARK: Startup timeout

    /// True when a `.starting` tunnel has been silent-or-stuck for `timeout`.
    /// Measured from the first process output — certificate tunnels are silent
    /// for 20+ s while the token initialises — falling back to state change /
    /// launch time so a completely hung process is still caught.
    static func isStartupTimedOut(now: Date, firstOutputAt: Date?, lastStateChange: Date?,
                                  launchedAt: Date?, timeout: TimeInterval) -> Bool {
        let started = firstOutputAt ?? lastStateChange ?? launchedAt ?? now
        return now.timeIntervalSince(started) >= timeout
    }

    // MARK: Connect-and-wait retry

    /// Whether `connectAndWait` may quietly start another client after a
    /// failure. A missed 2FA prompt is left to the watchdog, which owns the
    /// 2FA retry budget — retrying here too would send extra prompts.
    static func canRetryDuringStartup(lastError: TunnelError?, attempts: Int, limit: Int) -> Bool {
        guard let lastError, lastError.isRetryable, lastError != .twoFactorTimeout else { return false }
        return attempts <= limit
    }
}
