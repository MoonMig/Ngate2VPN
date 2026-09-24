import SwiftUI
import AppKit

// MARK: - Reusable helpers

struct FormBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(title).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.sec)
                .padding(.horizontal, 2).padding(.bottom, 5)
            VStack(spacing: 0) { content() }
                .background(DS.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.rL))
                .overlay(RoundedRectangle(cornerRadius: DS.rL).stroke(DS.border, lineWidth: 1))
        }
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 10) {
            Text(L(label))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.sec)
                .lineLimit(1)
                // Russian labels ("Название", "Бинарник") are wider than the
                // English ones; a too-narrow column wrapped their last letter.
                .frame(width: AppLanguage.effective == .ru ? 84 : 58, alignment: .trailing)
            content().frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { DS.border.frame(height: 1) }
    }
}

struct ToggleRow: View {
    let label: String
    let icon: String
    @Binding var value: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.accent).frame(width: 18)
            Text(L(label))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.pri)
            Spacer()
            RoundedToggle(isOn: value, color: DS.accent, busy: false) { value.toggle() }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { DS.border.frame(height: 1) }
    }
}

struct Pill: View {
    let title: String; let active: Bool; let action: () -> Void
    init(_ title: String, active: Bool, action: @escaping () -> Void) {
        self.title = title; self.active = active; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(L(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? DS.accent : DS.sec)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(active ? DS.accentDim : DS.surfaceHi, in: Capsule())
        }.buttonStyle(.plain)
    }
}

/// Plain text button for sheet headers — Cancel/Save in macOS style.
/// Uses onTapGesture instead of Button so SwiftUI cannot apply the system
/// "default action" blue bezel that appears when a sheet is presented.
struct SheetTextButton: View {
    let label: String
    let color: Color
    let bold: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    init(_ label: String,
         color: Color,
         bold: Bool = false,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.label = label
        self.color = color
        self.bold = bold
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Text(L(label))
            .font(.system(size: 13, weight: bold ? .semibold : .regular))
            .foregroundStyle(enabled ? color.opacity(hovered ? 0.7 : 1.0) : color.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .onHover { hovered = enabled && $0 }
            .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

struct SmallButton: View {
    let label: String
    let primary: Bool
    let enabled: Bool
    let tintColor: Color?
    let action: () -> Void
    @State private var hovered = false

    init(_ label: String,
         primary: Bool,
         tintColor: Color? = nil,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.label = label
        self.primary = primary
        self.tintColor = tintColor
        self.enabled = enabled
        self.action = action
    }

    private var baseTint: Color { tintColor ?? DS.accent }

    private var fillColor: Color {
        if !enabled {
            return primary ? baseTint.opacity(0.35) : DS.surface
        }
        if primary {
            return hovered ? baseTint.opacity(0.8) : baseTint
        }
        return hovered ? DS.surfaceHi : DS.surface
    }

    private var textColor: Color {
        if !enabled { return primary ? Color.white.opacity(0.6) : DS.ter }
        return primary ? .white : DS.sec
    }

    var body: some View {
        Button(action: action) {
            Text(L(label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(fillColor)
                )
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(primary ? Color.clear : DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = enabled && $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}

// MARK: - TextField helpers

extension TextField {
    func plain() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(DS.pri)
    }
}

extension SecureField {
    func plain() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(DS.pri)
    }
}

// SettingsView removed — settings are now in AppSettingsView (Settings tab in main window).

// MARK: - Native context menu

/// A right-click menu built from a real `NSMenu`.
///
/// SwiftUI's `.contextMenu` renders items natively on macOS and ignores text
/// colour, so a red "Delete" cannot be done with it. This attaches an AppKit
/// view that only claims right-clicks (and ctrl-clicks) — every other event
/// falls through to the SwiftUI view underneath — and pops up an `NSMenu`
/// whose destructive items carry a red attributed title and icon.
struct NativeContextMenu: NSViewRepresentable {
    enum Entry {
        case item(title: String, symbol: String, enabled: Bool = true, destructive: Bool = false, action: () -> Void)
        case separator
    }

    /// Called at click time, so the entries always reflect current state.
    let entries: () -> [Entry]

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.entries = entries
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.entries = entries
    }

    final class RightClickView: NSView {
        var entries: (() -> [Entry])?

        // Claim only right-clicks; let hover, left clicks and drags reach SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isSecondaryClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isSecondaryClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { popUp(with: event) }
        override func mouseDown(with event: NSEvent) { popUp(with: event) }

        private func popUp(with event: NSEvent) {
            guard let entries = entries?() else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case let .item(title, symbol, enabled, destructive, action):
                    let target = MenuAction(action)
                    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
                    item.target = target
                    item.representedObject = target      // target is unowned by NSMenuItem
                    item.isEnabled = enabled
                    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    if destructive {
                        item.attributedTitle = NSAttributedString(
                            string: title,
                            attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)]
                        )
                        item.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
                    } else {
                        item.image = image
                    }
                    menu.addItem(item)
                }
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private final class MenuAction: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
        @objc func fire() { block() }
    }
}
