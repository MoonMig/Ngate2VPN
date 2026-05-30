import AppKit
import SwiftUI

@MainActor
class StatusIconManager {
    private var statusItem: NSStatusItem?
    private var currentColor: NSColor = .gray
    private var baseGlobeImage: NSImage?   // сохраняем оригинальный чёрный глобус

    init() {}

    func setup(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        // Предзагружаем оригинальное изображение глобуса
        baseGlobeImage = createBaseGlobeImage()
        updateIcon(connectedCount: 0, totalTunnels: 0)

        if let button = statusItem.button {
            button.action = #selector(toggleWindow)
            button.target = self
        }
    }

    @objc func toggleWindow() {
        NotificationCenter.default.post(name: NSNotification.Name("ToggleMainWindow"), object: nil)
    }

    func updateIcon(connectedCount: Int, totalTunnels: Int) {
        let color: NSColor
        if connectedCount == 0 {
            color = NSColor.white
        } else if connectedCount == totalTunnels && totalTunnels > 0 {
            color = NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1.0) // зелёный — все подключены
        } else {
            color = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0) // синий — частично подключены
        }

        currentColor = color
        if let button = statusItem?.button {
            button.image = tintGlobeImage(color: color)
        }
    }

    // Создаём оригинальный чёрный глобус из SF Symbols
    private func createBaseGlobeImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = false   // будем перекрашивать вручную
        return image
    }

    // Перекрашиваем глобус в заданный цвет
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