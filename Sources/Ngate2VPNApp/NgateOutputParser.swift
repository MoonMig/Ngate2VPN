import Foundation

// MARK: - NgateOutputParser

/// Pure parsing of `ngateconsoleclient` stdout into structured signals.
///
/// Everything in this namespace is referentially transparent: it takes a
/// raw log line in and returns a value out, with no dependency on
/// `AppState`, runtime mutation, the main actor, or any I/O. That makes
/// it trivially testable and means we can change the keyword set without
/// risking a regression elsewhere in the app.
///
/// **Why pull this out of AppState.** Error classification is the most
/// fragile / churn-prone code in the app — every new ngate version may
/// emit a slightly different phrase. Keeping it in `AppState` (1100+
/// lines, `@MainActor`, `ObservableObject`) made it tedious to reason
/// about. It belongs in a small, focused file.
///
/// **Stable contract.** Method names match the originals in `AppState`,
/// and the keyword lists are byte-for-byte the same — this is a
/// **mechanical refactor**, no behavioural change.
enum NgateOutputParser {

    // MARK: Error classification

    /// Maps a single normalized (lowercased) ngate log line to a
    /// `TunnelError` if it carries one of the known failure phrases.
    /// Returns `nil` for ordinary informational / debug lines.
    ///
    /// The order of the checks matters:
    ///   - more specific phrases (e.g. invalid endpoint) come before
    ///     more general ones (e.g. gateway unreachable);
    ///   - we deliberately classify some lines as non-retryable
    ///     `invalidEndpoint` even when the underlying socket symptom
    ///     looks transient, because in practice a "connection closed
    ///     during connect" is almost always a wrong URL or port.
    static func classifyError(from normalizedLine: String) -> TunnelError? {
        if normalizedLine.contains("incorrect pin code entered") ||
            normalizedLine.contains("unspecified pin code error") ||
            normalizedLine.contains("invalid credentials") ||
            normalizedLine.contains("authentication failed") ||
            normalizedLine.contains("access denied") ||
            normalizedLine.contains("username/password combination has been tried") ||
            normalizedLine.contains("password combination has been tried") {
            return .invalidCredentials
        }
        if normalizedLine.contains("no certificates acquired") ||
            normalizedLine.contains("certificate not found") {
            return .certificateNotFound
        }
        if normalizedLine.contains("invalid certificate hash") ||
            normalizedLine.contains("certificate hash mismatch") {
            return .invalidCertificateHash
        }
        // Server's TLS certificate doesn't match the URL's host name.
        // Distinct from `invalidCertificateHash` (which is about our
        // own client cert pinning); this is the server side: typical
        // when the gateway has an expired, self-signed, or mis-issued
        // certificate, or the user has the wrong URL. Non-retryable —
        // either the admin fixes the cert or the user fixes the URL.
        if normalizedLine.contains("the host name did not match")
            || normalizedLine.contains("host name did not match any of the valid hosts")
            || normalizedLine.contains("certificate hostname mismatch")
            || normalizedLine.contains("certificate is not valid for")
            || (normalizedLine.contains("certificate") &&
                normalizedLine.contains("hostname") &&
                normalizedLine.contains("mismatch")) {
            return .serverCertificateNameMismatch
        }
        if normalizedLine.contains("network is unreachable") ||
            normalizedLine.contains("network unreachable") {
            return .networkUnreachable
        }
        if normalizedLine.contains("connection refused") {
            return .connectionRefused
        }
        // Server-side session refresh failed — typically token expiry or
        // server-side reset. Retryable (re-establishing the session usually works).
        //
        // We deliberately do NOT match the standalone phrase
        // "vpn session destroyed" here, even though it sounds like
        // it should belong. That string is a **finalization event**
        // ngate prints whenever an `Vx…` session object tears down,
        // regardless of cause. It fires after fatal errors too
        // (e.g. `No certificates acquired by SHA1 hash` → fatal,
        // then ngate emits `VPN session destroyed.` while
        // cleaning up). If we classified that line as a retryable
        // session-refresh failure, it would overwrite the earlier,
        // correct, non-retryable classification — and the watchdog
        // would retry forever on an unrecoverable error.
        // Genuine server-side disconnects already match the more
        // specific markers below (`RefreshTransaction`,
        // `session closed by server`, `VPN session closed` +
        // `unexpected status code`), so we don't lose coverage by
        // dropping the broad finalization match.
        // "Unable to correctly logout from remote gate. VPN session closed."
        // ngate emits this when the server closes the session while the client
        // is trying to disconnect cleanly — a server-side termination, not a
        // local configuration problem. Retryable: re-establishing the session
        // usually works.
        if normalizedLine.contains("refreshtransaction") ||
            (normalizedLine.contains("vpn session closed") && normalizedLine.contains("unexpected status code")) ||
            normalizedLine.contains("session closed by server") ||
            normalizedLine.contains("unable to correctly logout from remote gate") {
            return .sessionRefreshFailed
        }
        // Invalid endpoint — wrong/unresolvable URL. Not retryable.
        // "RemoteHostClosedError ... while connecting" specifically means the
        // socket got hung up during the connect handshake — almost always a
        // wrong URL or port, not a runtime network blip.
        if normalizedLine.contains("could not resolve host") ||
            normalizedLine.contains("name or service not known") ||
            normalizedLine.contains("nodename nor servname provided") ||
            normalizedLine.contains("dns lookup failed") ||
            normalizedLine.contains("hostname lookup failed") ||
            normalizedLine.contains("invalid url") ||
            normalizedLine.contains("malformed url") ||
            normalizedLine.contains("unable to parse url") ||
            normalizedLine.contains("unsupported scheme") ||
            normalizedLine.contains("no such host") ||
            (normalizedLine.contains("remotehostclosederror") && normalizedLine.contains("while connecting")) {
            return .invalidEndpoint
        }
        if normalizedLine.contains("remotehostclosederror") ||
            normalizedLine.contains("gateway unreachable") ||
            normalizedLine.contains("host unreachable") {
            return .gatewayUnreachable
        }
        return nil
    }

    // MARK: Reconnect detection

    /// True when the ngate client is announcing its own internal
    /// reconnect attempt — meaning we should not treat the next failure
    /// signal as a fresh connection error, and the watchdog should let
    /// ngate handle it.
    static func indicatesNgateReconnect(from normalizedLine: String) -> Bool {
        normalizedLine.contains("reconnecting") ||
        normalizedLine.contains("reconnect attempt") ||
        normalizedLine.contains("trying to reconnect") ||
        normalizedLine.contains("attempting reconnect") ||
        normalizedLine.contains("restoring connection") ||
        normalizedLine.contains("connection lost, retrying")
    }

    // MARK: ClientAddress extraction

    /// Pulls the issued tunnel IP out of an ngate JSON-style log line of
    /// the shape `…"ClientAddress":"10.0.0.42"…`. Returns `nil` if the
    /// line doesn't contain that key or the value is empty.
    ///
    /// We split on `"` rather than parsing JSON properly because ngate's
    /// "JSON" output is actually log-line-flavoured: it embeds JSON
    /// fragments inside otherwise unstructured text, occasionally with
    /// trailing tabs or partial payloads. Splitting on the quote
    /// character is robust to that mess.
    static func extractClientAddress(from line: String) -> String? {
        guard line.contains("\"ClientAddress\"") else { return nil }
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        guard let keyIndex = parts.firstIndex(of: "ClientAddress") else { return nil }
        let valueIndex = parts.index(keyIndex, offsetBy: 2, limitedBy: parts.index(before: parts.endIndex))
        guard let valueIndex else { return nil }
        let value = String(parts[valueIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
