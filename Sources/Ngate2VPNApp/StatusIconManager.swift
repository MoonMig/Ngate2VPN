import AppKit
import SwiftUI

@MainActor
class StatusIconManager {
    private var statusItem: NSStatusItem?
    private var baseGlobeImage: NSImage?

    init() {}

    func setup(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        baseGlobeImage = createBaseGlobeImage()
        updateIcon(connectedCount: 0, totalTunnels: 0)
    }

    func updateIcon(connectedCount: Int, totalTunnels: Int) {
        let color: NSColor
        if connectedCount == 0 {
            // Use secondary label color — visible on both light and dark menu bars.
            color = NSColor.secondaryLabelColor
        } else if connectedCount == totalTunnels && totalTunnels > 0 {
            color = NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1.0)
        } else if connectedCount >= 2 {
            color = NSColor(red: 0.2, green: 0.4, blue: 1.0, alpha: 1.0)
        } else {
            color = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0)
        }

        if let button = statusItem?.button {
            button.image = tintGlobeImage(color: color)
        }
    }

    private func createBaseGlobeImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = false
        return image
    }

    private func tintGlobeImage(color: NSColor) -> NSImage? {
        guard let base = baseGlobeImage else { return nil }
        let tintedImage = NSImage(size: base.size)
        tintedImage.lockFocus()
        let ctx = NSGraphicsContext.current?.cgContext
        let rect = CGRect(origin: .zero, size: base.size)
        ctx?.clear(rect)
        color.setFill()
        ctx?.fill(rect)
        base.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1.0)
        tintedImage.unlockFocus()
        return tintedImage
    }
}
