import SwiftUI
import AppKit

// MARK: - LogTextView (NSTextView-backed for cross-line selection)

/// `NSTextView` subclass whose only job is to keep the layout manager in
/// sync with the text-view frame at every step of a live window resize.
///
/// Why this exists: `NSLayoutManager` defers full re-flow during live
/// resize as a performance optimisation. With a vanilla `NSTextView` you
/// see the text "freeze" at the wrap position it had when the drag began,
/// and only after you release the mouse does AppKit do the final relayout
/// — which makes the last few words abruptly jump to a new line.
///
/// Overriding `setFrameSize(_:)` puts our re-flow code on every single
/// pixel of resize (this method is called by AppKit during the drag,
/// inside the `eventTracking` runloop mode). We force the container
/// geometry to match the new width and notify the layout manager
/// explicitly via `textContainerChangedGeometry(_:)`, which bypasses the
/// usual deferral and gives smooth, continuous re-wrapping.
///
/// **Stick-to-bottom is also handled here, synchronously.** If we left it
/// to a separate `frameDidChangeNotification` observer that posted a
/// `Task { @MainActor in scrollToBottom() }`, there would be a frame in
/// every drag tick where the layout had updated but the scroll position
/// hadn't yet — visible as flicker only when the viewport was at the
/// bottom (in the middle of the log there's nothing to flicker, the
/// scroll position is unchanged either way). Capturing "was the user
/// near the bottom?" before super.setFrameSize and re-applying scroll
/// **after** the geometry update — all inside the same call — eliminates
/// that frame entirely.
private final class WrappingLogTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        // Capture the user's visual reference point BEFORE any layout
        // changes happen.
        let shouldStickToAbsoluteBottom = isViewportAtBottom()
        let bottomAnchorChar = shouldStickToAbsoluteBottom
            ? nil
            : lastVisibleCharacterIndex()

        super.setFrameSize(newSize)
        guard let layoutManager, let textContainer else { return }
        let inset = textContainerInset
        let newContainerWidth = max(1, newSize.width - inset.width * 2)
        if abs(textContainer.containerSize.width - newContainerWidth) >= 0.5 {
            textContainer.containerSize = NSSize(
                width: newContainerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.textContainerChangedGeometry(textContainer)
        // ensureLayout(for: container) is the safe, non-recursive way
        // to flush layout. DO NOT use glyphRange(for: container) or
        // usedRect(for: container) here — those internally call
        // `_resizeTextViewForTextContainer`, which calls back into
        // setFrameSize, causing infinite recursion (cf. crash report
        // for 2.18 — bottomed out at ~12 800 stack frames).
        layoutManager.ensureLayout(for: textContainer)

        if shouldStickToAbsoluteBottom {
            scrollViewportToBottom()
        } else if let charIdx = bottomAnchorChar {
            scrollCharacterToViewportBottom(charIdx)
        }
    }

    /// Returns true when the user is reading the live tail of the log.
    /// Threshold of 24 pt allows for sub-pixel drift from re-layouts
    /// without losing the "is sticking" signal.
    fileprivate func isViewportAtBottom(threshold: CGFloat = 24) -> Bool {
        guard let scrollView = enclosingScrollView else { return true }
        let documentHeight = frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        let currentY = scrollView.contentView.bounds.origin.y
        let maxY = max(0, documentHeight - viewportHeight)
        return maxY - currentY <= threshold
    }

    /// Pins the visible viewport to the bottom of the document. Uses
    /// `frame.height` (not `usedRect`) because reading `usedRect(for:)`
    /// internally re-enters `setFrameSize` and recurses.
    fileprivate func scrollViewportToBottom() {
        guard let scrollView = enclosingScrollView else { return }
        let documentHeight = frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        let maxY = max(0, documentHeight - viewportHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Returns the character index of the **last** character currently
    /// visible in the viewport — the user's natural visual anchor when
    /// reading the bottom of the journal.
    ///
    /// **Implementation.** We probe `glyphIndex(for: in:)` at the
    /// bottom-right corner of the viewport (in container coordinates),
    /// minus one point so we land inside the last visible line rather
    /// than rounding into the line below or off the end of the
    /// document. Bottom-RIGHT (not bottom-left) is critical: if a log
    /// line wraps to two visual lines, the bottom-left point would hit
    /// the START of the bottom visual line, while the bottom-right
    /// point hits its END — which is what the user sees as their
    /// anchor point.
    ///
    /// Previous attempts:
    ///   * `glyphIndex(for: bottomLeft, in:)` returned the first glyph
    ///     of the bottom line. After reflow that line might wrap into
    ///     two visual lines and our anchor (its first glyph) was
    ///     above the new visual bottom.
    ///   * `glyphRange(forBoundingRect: viewport, in:)` excludes line
    ///     fragments that are only partially visible at the bottom
    ///     edge, so we'd return a character one line higher than the
    ///     user's actual visual anchor.
    private func lastVisibleCharacterIndex() -> Int? {
        guard let scrollView = enclosingScrollView,
              let layoutManager,
              let textContainer else { return nil }
        guard layoutManager.numberOfGlyphs > 0 else { return nil }

        let visibleRect = scrollView.contentView.documentVisibleRect
        // Make sure layout exists for every line currently on screen.
        layoutManager.ensureLayout(for: textContainer)

        // Bottom-right corner of the viewport in textContainer coords.
        // -1 keeps us inside the last visible line.
        let probePoint = NSPoint(
            x: max(0, visibleRect.maxX - textContainerOrigin.x - 1),
            y: max(0, visibleRect.maxY - textContainerOrigin.y - 1)
        )
        let glyphIdx = layoutManager.glyphIndex(for: probePoint, in: textContainer)
        let safeGlyphIdx = min(glyphIdx, max(0, layoutManager.numberOfGlyphs - 1))
        return layoutManager.characterIndexForGlyph(at: safeGlyphIdx)
    }

    /// Scrolls so the line containing `charIdx` sits at the bottom
    /// of the viewport. Used to preserve the user's reading anchor
    /// across a reflow.
    private func scrollCharacterToViewportBottom(_ charIdx: Int) {
        guard let scrollView = enclosingScrollView,
              let layoutManager,
              let textContainer else { return }

        let textLength = (string as NSString).length
        guard textLength > 0 else { return }
        let safeCharIdx = max(0, min(charIdx, textLength - 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeCharIdx, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return }

        let charBounds = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        let bottomInTextView = charBounds.maxY + textContainerOrigin.y
        let viewportHeight = scrollView.contentView.bounds.height
        let targetY = max(0, bottomInTextView - viewportHeight)
        // No manual clamp via documentHeight — reading `usedRect(for:)`
        // re-enters setFrameSize and recurses (crash in 2.18). NSClipView's
        // own clamping at scroll time keeps us in the legal range.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Wraps NSTextView so the user can select and copy text across multiple lines,
/// just like in any native macOS text area. Lines are rendered as one
/// continuous attributed string with severity-based colouring.
///
/// **Performance.** Older versions rebuilt the entire `NSAttributedString`
/// from scratch on every SwiftUI update, which was O(N) per added line and
/// became visibly laggy after a few thousand entries. Now we detect the
/// common case where SwiftUI has just appended new entries to a previously
/// rendered list, and only build / append the new tail — turning a fresh
/// log line into an O(K) operation where K is the number of new lines, no
/// matter how big the journal has grown. Filter changes, profile switches
/// and Clear still trigger a single full rebuild.
struct LogTextView: NSViewRepresentable {
    let entries: [UnifiedLogEntry]
    let showTunnelTag: Bool

    /// Single-line tunnel-tag colour — blue accent. Hoisted so we don't
    /// allocate it per line during rebuilds.
    private static let tagColor = NSColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1.0)
    /// SYSTEM tag colour — orange to match its severity colour.
    private static let systemTagColor = NSColor(red: 1.00, green: 0.62, blue: 0.18, alpha: 1.0)
    private static let logFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let tagFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // No frame-change notifications: stick-to-bottom during resize
        // is handled synchronously inside WrappingLogTextView, so we
        // don't need an asynchronous notification observer.

        let contentSize = scrollView.contentSize
        let textView = WrappingLogTextView(
            frame: NSRect(origin: .zero, size: contentSize)
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.isEditable = false
        textView.isSelectable = true                       // cross-line selection works here
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 14, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = Self.logFont
        textView.layoutManager?.allowsNonContiguousLayout = false

        scrollView.documentView = textView
        context.coordinator.configure(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coord = context.coordinator
        let newCount = entries.count
        let oldCount = coord.entryCount
        let wasNearBottom = coord.isNearBottom()

        // Decide between incremental append and full rebuild.
        //
        // Append-only path requires that the entries we already rendered
        // are exactly the same as the prefix of the new array. Since
        // SwiftUI re-creates UnifiedLogEntry instances (their UUIDs are
        // ephemeral), we use the text of the boundary entry as a cheap
        // fingerprint — the journal is purely additive, so position/text
        // pairs are stable over an append. Anything else (filter change,
        // profile switch, Clear) trips the fingerprint check and falls
        // back to a single setAttributedString.
        let canAppend: Bool
        if oldCount == 0 {
            canAppend = false
        } else if newCount < oldCount {
            // Entry list shrank — definitely a Clear or filter change.
            canAppend = false
        } else if let fingerprint = coord.lastBoundaryFingerprint,
                  oldCount - 1 < newCount,
                  entries[oldCount - 1].text == fingerprint {
            canAppend = true
        } else {
            canAppend = false
        }

        if canAppend, let storage = textView.textStorage {
            // Build attributed string for just the new tail and append.
            let appended = Self.buildAttributedString(
                for: entries[oldCount..<newCount],
                showTunnelTag: showTunnelTag,
                leadingNewline: oldCount > 0
            )
            storage.append(appended)
        } else {
            // Full rebuild — also covers initial render and Clear.
            textView.textStorage?.setAttributedString(
                Self.buildAttributedString(
                    for: entries[0..<newCount],
                    showTunnelTag: showTunnelTag,
                    leadingNewline: false
                )
            )
        }

        coord.entryCount = newCount
        coord.lastBoundaryFingerprint = entries.last?.text

        // Scroll-to-bottom decision:
        //
        // **Full rebuild** (initial render, profile switch, filter
        // change, Clear) — always land at the bottom. The user has
        // just changed *what* they're looking at; the natural default
        // is to see the most recent events of the new view, not
        // wherever the previous viewport happened to be.
        //
        // **Append-only** — respect the user's reading position. If
        // they've scrolled up to read history, leave them there. Only
        // follow the live tail when they were already near the bottom.
        let shouldScrollToBottom: Bool
        if !canAppend {
            shouldScrollToBottom = newCount > 0
        } else {
            shouldScrollToBottom = newCount > oldCount && wasNearBottom
        }

        if shouldScrollToBottom {
            DispatchQueue.main.async {
                coord.scrollToBottom()
            }
        }
    }

    /// Builds an `NSAttributedString` for an arbitrary slice of entries.
    /// `leadingNewline` adds a separator in front so the produced fragment
    /// can be appended to existing text without merging into the previous
    /// line.
    private static func buildAttributedString(
        for slice: ArraySlice<UnifiedLogEntry>,
        showTunnelTag: Bool,
        leadingNewline: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !slice.isEmpty else { return result }

        if leadingNewline {
            result.append(NSAttributedString(string: "\n"))
        }

        let indices = Array(slice.indices)
        for (offset, idx) in indices.enumerated() {
            let entry = slice[idx]
            let isSystem = entry.text.contains("[SYSTEM]")

            if isSystem {
                // System entries arrive as "yyyy-MM-dd HH:mm:ss [SYSTEM] [profile] message"
                // (or for bulk system, "yyyy-MM-dd HH:mm:ss [SYSTEM] message").
                //
                // We render them so the orange [SYSTEM] tag comes
                // FIRST, then the timestamp, then the message — same
                // visual order as ngate lines, where the [profile]
                // tag is prepended ahead of ngate's own timestamp.
                // This keeps the journal column-aligned: every row
                // starts with a coloured tag of fixed-ish width, then
                // the time, then the body.
                // Strip the [SYSTEM] tag (followed by space or tab) so the renderer
                // can prepend a freshly styled orange "[SYSTEM] " in its place.
                let trimmed = entry.text
                    .replacingOccurrences(of: "[SYSTEM] ", with: "")
                    .replacingOccurrences(of: "[SYSTEM]\t", with: "")
                // trimmed is now: "yyyy-MM-dd HH:mm:ss.SSS Info\t[profile] message"
                // or "yyyy-MM-dd HH:mm:ss.SSS Warning\tmessage" etc.
                let displayText = displaySafeLine(trimmed)

                result.append(NSAttributedString(
                    string: "[SYSTEM] ",
                    attributes: [.font: tagFont, .foregroundColor: systemTagColor]
                ))
                result.append(NSAttributedString(
                    string: displayText,
                    attributes: [.font: logFont, .foregroundColor: nsColor(for: entry.text)]
                ))
            } else {
                let displayText = displaySafeLine(entry.text)

                if showTunnelTag, let tunnelTitle = entry.tunnelTitle {
                    let tag = NSAttributedString(
                        string: "[\(tunnelTitle)] ",
                        attributes: [.font: tagFont, .foregroundColor: tagColor]
                    )
                    result.append(tag)
                }

                let color = nsColor(for: entry.text)
                let line = NSAttributedString(
                    string: displayText,
                    attributes: [.font: logFont, .foregroundColor: color]
                )
                result.append(line)
            }

            if offset < indices.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    /// ngate sometimes emits tabs between the severity token and JSON
    /// payload. NSTextView expands tabs to wide tab stops and wraps there
    /// even when the visible text would otherwise fit. Display them as
    /// spaces while keeping each log entry a single logical line.
    private static func displaySafeLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func nsColor(for line: String) -> NSColor {
        // Match coloring to the detected level TOKEN only — same logic as
        // the Journal filter, so we don't accidentally color a Debug line
        // red just because the message body contains words like "failed".
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for token in tokens {
            switch token.lowercased() {
            case "critical", "error":
                return NSColor(red: 1.00, green: 0.33, blue: 0.33, alpha: 0.9)
            case "warning":
                return NSColor(red: 1.00, green: 0.62, blue: 0.18, alpha: 0.9)
            case "debug", "info":
                // Stop scanning — we found the level token, anything after
                // it is the message body and must not influence colour.
                break
            default:
                continue
            }
            break
        }
        // Neutral text — adapts to current theme
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor.white.withAlphaComponent(0.5)
                : NSColor.black.withAlphaComponent(0.65)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        var entryCount = 0
        /// Text of the last entry we rendered. Used to detect whether the
        /// next SwiftUI update is a pure append (text matches) or a
        /// filter / clear change (text differs → full rebuild).
        var lastBoundaryFingerprint: String?

        func configure(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            // Stick-to-bottom during live resize is handled inside
            // WrappingLogTextView.setFrameSize, synchronously. We keep
            // scrollToBottom available here for the new-content path
            // driven from updateNSView.
        }

        func scrollToBottom() {
            guard let scrollView, let textView else { return }
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            let documentHeight = textView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let maxY = max(0, documentHeight - viewportHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func isNearBottom(threshold: CGFloat = 24) -> Bool {
            guard let scrollView, let textView else { return true }
            let documentHeight = textView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let currentY = scrollView.contentView.bounds.origin.y
            let maxY = max(0, documentHeight - viewportHeight)
            return maxY - currentY <= threshold
        }
    }
}
