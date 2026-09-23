import Foundation
import SwiftUI
import Combine
import CryptoKit

// Keychain-backed secrets (via SecretVault) and their resolution at connect time.
// Split out of AppState.swift; members are internal (not private) so the
// extensions in the sibling files can share state.
extension AppState {
    /// Stores the secret that matches the profile's auth method and drops the
    /// other one. An empty field means "unchanged" — profile forms never show
    /// stored secrets, so an untouched PIN/password arrives here empty.
    func saveSecretsIfNeeded(from configuration: TunnelConfiguration) {
        do {
            try vault.update(configuration.id) { entry in
                switch configuration.authMethod {
                case .certificate:
                    entry.password = nil
                    if !configuration.pinCode.isEmpty { entry.pin = configuration.pinCode }
                case .credentials:
                    entry.pin = nil
                    if !configuration.password.isEmpty { entry.password = configuration.password }
                }
            }
        } catch {
            appendSystemLog("Failed to save credentials to Keychain.", to: configuration.id, level: .warning)
        }
    }

    func deleteStoredSecrets(for tunnelID: UUID) {
        do {
            try vault.remove(tunnelID)
        } catch {
            appendSystemLog("Failed to delete credentials from Keychain.", to: tunnelID, level: .warning)
        }
    }

    /// - Parameter quiet: background use (pre-warming) — return nil on any
    ///   problem without logging, alerting, or failing the tunnel.
    func resolvedConfigurationForStart(tunnelID: UUID, from configuration: TunnelConfiguration, quiet: Bool = false) -> TunnelConfiguration? {
        var resolved = Self.sanitizedConfiguration(configuration)
        do {
            switch resolved.authMethod {
            case .certificate:
                guard let pin = try vault.pin(for: tunnelID), !pin.isEmpty else {
                    if quiet { return nil }
                    let message = "PIN not found in Keychain. Open the profile and save your PIN first."
                    appendSystemLog(message, to: tunnelID, level: .error)
                    transitionState(id: tunnelID, newState: .failed, errorMessage: message, tunnelError: .launchFailed)
                    showAlert(title: "PIN Required", message: message, for: tunnelID)
                    return nil
                }
                resolved.pinCode = pin
            case .credentials:
                guard let password = try vault.password(for: tunnelID), !password.isEmpty else {
                    if quiet { return nil }
                    let message = "Password not found in Keychain. Open the profile and save your password first."
                    appendSystemLog(message, to: tunnelID, level: .error)
                    transitionState(id: tunnelID, newState: .failed, errorMessage: message, tunnelError: .launchFailed)
                    showAlert(title: "Password Required", message: message, for: tunnelID)
                    return nil
                }
                resolved.password = password
            }
        } catch {
            if quiet { return nil }
            let message = "Failed to load credentials."
            appendSystemLog(message, to: tunnelID, level: .error)
            transitionState(id: tunnelID, newState: .failed, errorMessage: message, tunnelError: .launchFailed)
            showAlert(title: "Keychain Error", message: message, for: tunnelID)
            return nil
        }
        return resolved
    }

    static func sanitizedConfiguration(_ configuration: TunnelConfiguration) -> TunnelConfiguration {
        var sanitized = configuration
        sanitized.pinCode = ""
        sanitized.password = ""
        return sanitized
    }

    /// Profiles saved by very old builds kept the PIN / password inside the
    /// persisted JSON: this moves them to the Keychain and strips them from
    /// memory (the caller persists afterwards). A no-op on current data, where
    /// secrets are never persisted. Must run on the *unsanitized* loaded
    /// profiles — see `AppState.init`.
    func migratePersistedSecretsToKeychainIfNeeded() {
        tunnels = tunnels.map { configuration in
            if !configuration.pinCode.isEmpty || !configuration.password.isEmpty {
                saveSecretsIfNeeded(from: configuration)
            }
            return Self.sanitizedConfiguration(configuration)
        }
    }

}
