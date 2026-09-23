import SwiftUI
import AppKit

// MARK: - HOME

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingID: UUID?
    @State private var deletingID: UUID?
    @State private var showDeleteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Sub-header — fixed height keeps everything vertically centered
            HStack(alignment: .center, spacing: 10) {
                Text("Ngate2VPN")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.pri)
                Spacer()
                SmallButton("Connect All",
                            primary: true,
                            enabled: !appState.allTunnelsActive) { appState.connectAll() }
                SmallButton("Disconnect All",
                            primary: true,
                            tintColor: DS.red,
                            enabled: appState.anyTunnelActive) { appState.disconnectAll() }
                Divider().frame(height: 16).background(DS.border)
                Button { appState.addTunnel() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.accent)
                        .frame(width: 24, height: 24)
                        .background(DS.accentDim, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("New profile")
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(DS.surface)


            if appState.tunnels.isEmpty {
                EmptyProfiles { appState.addTunnel() }
            } else {
                // List supports .onMove (drag-to-reorder); we strip its native
                // chrome to keep the look consistent with the rest of the app.
                List {
                    ForEach(appState.tunnels) { tunnel in
                        ProfileRow(
                            tunnelID: tunnel.id,
                            onEdit:   { editingID = tunnel.id },
                            onDelete: { deletingID = tunnel.id; showDeleteAlert = true }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(DS.bg)
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(DS.border)
                        .alignmentGuide(.listRowSeparatorLeading)  { _ in 9 }
                        .alignmentGuide(.listRowSeparatorTrailing) { d in d.width - 9 }
                    }
                    .onMove { source, destination in
                        appState.tunnels.move(fromOffsets: source, toOffset: destination)
                        appState.persist()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(DS.bg)
            }
        }
        // Edit sheet
        .sheet(item: Binding<ID?>(
            get: {
                guard let id = editingID else { return nil }
                return ID(value: id)
            },
            set: { editingID = $0?.value }
        )) { w in
            EditSheet(tunnelID: w.value).environmentObject(appState)
        }
        // Delete confirmation
        .confirmationDialog("Delete Profile?", isPresented: $showDeleteAlert, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deletingID.map { appState.removeTunnel($0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

private struct ID: Identifiable { let value: UUID; var id: UUID { value } }

struct EmptyProfiles: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shield.slash").font(.system(size: 36, weight: .thin)).foregroundStyle(DS.ter)
            Text("No profiles").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.sec)
            SmallButton("Add Profile", primary: true, action: onAdd)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    @EnvironmentObject private var appState: AppState
    let tunnelID: UUID
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false
    @State private var copied = false

    private func dotColor(_ s: TunnelState) -> Color {
        switch s {
        case .running:            return DS.green
        case .degraded:           return DS.orange
        case .starting,.stopping: return DS.orange
        case .failed:             return DS.red
        case .stopped:            return DS.muted
        }
    }

    var body: some View {
        if let snap = appState.snapshot(for: tunnelID) {
            let st = snap.runtime.status
            let active = st == .running || st == .degraded
            let busy   = st == .starting || st == .stopping

            HStack(spacing: 14) {
                // Icon bubble
                ZStack {
                    Circle().fill(dotColor(st).opacity(0.14)).frame(width: 38, height: 38)
                    Image(systemName: "shield.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(dotColor(st))
                }

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    Text(snap.configuration.title.isEmpty ? "Untitled" : snap.configuration.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.pri)
                        .lineLimit(1)
                    Text(snap.configuration.endpointURL.isEmpty ? st.title : snap.configuration.endpointURL)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.sec)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                // Status/IP badge
                if busy || (active && snap.runtime.clientAddress != nil) {
                    let badgeText = busy ? st.title : (copied ? "Copied" : (snap.runtime.clientAddress ?? ""))
                    let badgeColor = busy ? DS.orange : DS.green
                    Text(badgeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(badgeColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(badgeColor.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                        .onTapGesture {
                            guard !busy, let ip = snap.runtime.clientAddress else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                }

                // Toggle
                RoundedToggle(isOn: active || busy, color: dotColor(st), busy: busy) {
                    appState.toggleConnection(for: tunnelID)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: DS.r)
                    .fill(hovered ? DS.surfaceHi.opacity(0.6) : Color.clear)
            )
            .animation(.easeOut(duration: 0.1), value: hovered)
            .onHover { hovered = $0 }
            .overlay {
                NativeContextMenu {
                    var entries: [NativeContextMenu.Entry] = [
                        .item(title: "Edit Profile", symbol: "pencil") { onEdit() },
                        .separator,
                    ]
                    // Reorder — alternative to drag-and-drop
                    if let idx = appState.tunnels.firstIndex(where: { $0.id == tunnelID }) {
                        entries += [
                            .item(title: "Move Up", symbol: "arrow.up", enabled: idx > 0) { moveUp(currentIndex: idx) },
                            .item(title: "Move Down", symbol: "arrow.down", enabled: idx < appState.tunnels.count - 1) { moveDown(currentIndex: idx) },
                            .separator,
                        ]
                    }
                    entries.append(.item(title: "Delete Profile", symbol: "trash", destructive: true) { onDelete() })
                    return entries
                }
            }
        }
    }

    private func moveUp(currentIndex idx: Int) {
        guard idx > 0 else { return }
        appState.tunnels.swapAt(idx, idx - 1)
        appState.persist()
    }

    private func moveDown(currentIndex idx: Int) {
        guard idx < appState.tunnels.count - 1 else { return }
        appState.tunnels.swapAt(idx, idx + 1)
        appState.persist()
    }
}

// MARK: - Rounded Toggle

struct RoundedToggle: View {
    let isOn: Bool
    let color: Color
    let busy: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isOn ? color : DS.surfaceHi)
                .frame(width: 44, height: 26)
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                .offset(x: isOn ? 9 : -9)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isOn)
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.4)
                    .offset(x: isOn ? 9 : -9)
            }
        }
        .frame(width: 44, height: 26)
        .onTapGesture { onTap() }
        .opacity(busy ? 0.7 : 1)
    }
}
