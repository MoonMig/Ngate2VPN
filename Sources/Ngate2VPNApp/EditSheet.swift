import SwiftUI
import AppKit

// MARK: - Edit Sheet

struct EditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let tunnelID: UUID
    @State private var draft = TunnelConfiguration(title: "")

    private var hasChanges: Bool {
        guard let saved = appState.snapshot(for: tunnelID)?.configuration else { return false }
        return draft.title != saved.title
            || draft.endpointURL != saved.endpointURL
            || draft.authMethod != saved.authMethod
            || draft.serialNumber != saved.serialNumber
            || draft.username != saved.username
            || !draft.pinCode.isEmpty
            || !draft.password.isEmpty
            || draft.autoReconnect != saved.autoReconnect
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                SheetTextButton("Cancel", color: DS.red) { dismiss() }
                Spacer()
                Text("Edit Profile").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.pri)
                Spacer()
                SheetTextButton("Save",
                                color: hasChanges ? DS.accent : DS.ter,
                                bold: true,
                                enabled: hasChanges) {
                    appState.updateTunnel(draft); dismiss()
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(DS.surface)

            Divider().background(DS.border)

            ScrollView {
                VStack(spacing: 14) {
                    FormBlock("Profile") {
                        FieldRow(label: "Name")  { TextField("Profile name", text: $draft.title).plain() }
                        FieldRow(label: "URL")   { TextField("https://…",    text: $draft.endpointURL).plain() }
                    }
                    FormBlock("Connection") {
                        ToggleRow(label: "Auto-reconnect", icon: "arrow.clockwise", value: $draft.autoReconnect)
                    }
                    FormBlock("Auth") {
                        FieldRow(label: "Method") {
                            Picker("", selection: $draft.authMethod) {
                                ForEach(TunnelAuthMethod.allCases) { m in Text(m.title).tag(m) }
                            }.pickerStyle(.segmented)
                        }
                        if draft.authMethod == .certificate {
                            FieldRow(label: "SHA1") { TextField("Fingerprint", text: $draft.serialNumber).plain() }
                            FieldRow(label: "PIN")  { SecureField("Leave blank to keep", text: $draft.pinCode).plain() }
                        } else {
                            FieldRow(label: "Login")    { TextField("Username", text: $draft.username).plain() }
                            FieldRow(label: "Password") { SecureField("Leave blank to keep", text: $draft.password).plain() }
                        }
                    }
                    Text("Secrets are stored in macOS Keychain and never logged.")
                        .font(.system(size: 11)).foregroundStyle(DS.ter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
            .background(DS.bg)
        }
        .background(DS.bg)
        .frame(width: 420, height: 400)
        .onAppear {
            if let c = appState.snapshot(for: tunnelID)?.configuration { draft = c }
        }
    }
}
