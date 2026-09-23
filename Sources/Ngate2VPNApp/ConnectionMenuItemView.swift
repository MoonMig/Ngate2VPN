import AppKit

/// A tray-menu row showing a tunnel's name and its assigned IP address.
///
/// It is a custom `NSMenuItem.view` on purpose: clicking a normal menu item
/// always dismisses the menu, whereas a click inside a custom view does not.
/// That lets a click copy the IP, flash "Copied" in place, and leave the menu
/// open — the same feedback as the IP badge in the main window.
final class ConnectionMenuItemView: NSView {
    private static let sidePadding: CGFloat = 14
    private static let copiedFlashDuration: TimeInterval = 1.2

    private let nameField = ConnectionMenuItemView.makeLabel()
    private let ipField = ConnectionMenuItemView.makeLabel()
    private let ip: String
    private var showsCopied = false
    private var resetWork: DispatchWorkItem?
    private var hintWork: DispatchWorkItem?
    private var hoverGeneration = 0

    /// The row currently under the mouse. `mouseExited` is not delivered
    /// reliably while a menu is tracking, so entering a row explicitly clears
    /// the previous one instead of relying on it.
    private static weak var hoveredRow: ConnectionMenuItemView?
    private static let hintText = "Click to copy the IP address"

    private var highlighted = false {
        didSet {
            needsDisplay = true
            updateAppearance()
        }
    }

    init(name: String, ip: String) {
        self.ip = ip
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        autoresizingMask = [.width]
        nameField.stringValue = name
        ipField.stringValue = ip
        ipField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ipField.alignment = .right
        addSubview(nameField)
        addSubview(ipField)
        updateAppearance()
        // Observers registered by selector are dropped automatically on dealloc.
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidEndTracking), name: NSMenu.didEndTrackingNotification, object: nil
        )
        // Ask for exactly the width the text needs, so the menu grows to fit
        // instead of squeezing the labels into ellipses.
        frame.size.width = max(220, Self.sidePadding * 2 + Self.gap + nameWidth + ipColumnWidth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let gap: CGFloat = 16

    /// Width the text really occupies. `intrinsicContentSize` of a label is
    /// unreliable before it is in a window and led to needless truncation.
    private static func textWidth(_ field: NSTextField) -> CGFloat {
        ceil(NSAttributedString(string: field.stringValue, attributes: [.font: field.font as Any]).size().width) + 6
    }

    private var nameWidth: CGFloat { Self.textWidth(nameField) }

    /// The IP column is as wide as the IP or the "Copied" label, whichever is larger.
    private var ipColumnWidth: CGFloat {
        let copied = NSAttributedString(string: "Copied", attributes: [.font: ipField.font as Any]).size().width
        return max(Self.textWidth(ipField), ceil(copied) + 6)
    }

    private static func makeLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .menuFont(ofSize: 0)
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = false
        return field
    }

    // MARK: Layout & drawing

    override func layout() {
        super.layout()
        let pad = Self.sidePadding
        let height = ceil(max(nameField.font?.boundingRectForFont.height ?? 16, ipField.font?.boundingRectForFont.height ?? 16))
        let y = (bounds.height - height) / 2
        let ipWidth = ipColumnWidth
        // The name gets everything the IP column leaves; it only truncates if
        // the menu is genuinely narrower than the text needs.
        let nameSpace = max(0, bounds.width - 2 * pad - Self.gap - ipWidth)
        nameField.frame = NSRect(x: pad, y: y, width: min(nameWidth, nameSpace), height: height)
        ipField.frame = NSRect(x: bounds.width - pad - ipWidth, y: y, width: ipWidth, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    private func updateAppearance() {
        ipField.stringValue = showsCopied ? "Copied" : ip
        if highlighted {
            nameField.textColor = .selectedMenuItemTextColor
            ipField.textColor = .selectedMenuItemTextColor
        } else {
            nameField.textColor = .labelColor
            ipField.textColor = showsCopied ? .systemGreen : .secondaryLabelColor
        }
        needsLayout = true
    }

    // MARK: Hover & click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        if let previous = Self.hoveredRow, previous !== self { previous.endHover() }
        Self.hoveredRow = self
        highlighted = true
        startHoverWatch()
        scheduleHint()
    }

    override func mouseExited(with event: NSEvent) { endHover() }

    @objc private func menuDidEndTracking() { endHover() }

    private func endHover() {
        highlighted = false
        hoverGeneration += 1      // stops any pending pointer check
        cancelHint()
        if Self.hoveredRow === self { Self.hoveredRow = nil }
    }

    // MARK: Hover watchdog
    //
    // While a menu tracks the mouse, `mouseExited` is not delivered when the
    // pointer moves onto an ordinary item or leaves the menu, so the highlight
    // stuck. While highlighted, check the real pointer position instead.

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return window.convertToScreen(convert(bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    private func startHoverWatch() {
        hoverGeneration += 1
        watchPointer(generation: hoverGeneration)
    }

    /// Re-checks every 50 ms while highlighted. A chained main-queue block (not
    /// a Timer) so nothing outlives the view and nothing needs invalidating.
    private func watchPointer(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.highlighted, self.hoverGeneration == generation else { return }
            if self.pointerIsInside {
                self.watchPointer(generation: generation)
            } else {
                self.endHover()
            }
        }
    }

    // MARK: Hint
    //
    // Menus don't draw tooltips for custom-view items (neither `NSView.toolTip`
    // nor `NSMenuItem.toolTip` shows up), so the hint is a small panel of our own.

    private func scheduleHint() {
        cancelHint()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.highlighted, let window = self.window else { return }
            let onScreen = window.convertToScreen(self.convert(self.bounds, to: nil))
            HintPanel.shared.show(Self.hintText, belowRowAt: onScreen)
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func cancelHint() {
        hintWork?.cancel()
        hintWork = nil
        HintPanel.shared.hide()
    }

    override func mouseDown(with event: NSEvent) {
        cancelHint()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)

        showsCopied = true
        updateAppearance()
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showsCopied = false
            self?.updateAppearance()
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFlashDuration, execute: work)
        // Deliberately no cancelTracking(): the menu stays open.
    }
}

/// A minimal tooltip window shown above the menu (menus don't draw tooltips
/// for custom-view rows).
@MainActor
private final class HintPanel {
    static let shared = HintPanel()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ text: String, belowRowAt row: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let inset: CGFloat = 7
        let size = NSSize(width: label.frame.width + inset * 2, height: label.frame.height + 6)
        label.frame.origin = NSPoint(x: inset, y: 3)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: row.minX + 16, y: row.minY - size.height - 2))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
