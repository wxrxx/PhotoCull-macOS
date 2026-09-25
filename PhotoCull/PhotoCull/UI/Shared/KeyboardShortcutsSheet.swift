// KeyboardShortcutsSheet.swift
// PhotoCull
//
// A sheet-style window controller displaying a formatted keyboard shortcut
// cheat sheet. Present modally as a sheet or as a standalone window.
// Trigger: user presses '?' in the grid or detail view.

import AppKit

// MARK: - KeyboardShortcutsSheet

final class KeyboardShortcutsSheet: NSWindowController {

    // MARK: Lifecycle

    /// Convenience initialiser — builds the window programmatically.
    convenience init() {
        let window = Self.makeWindow()
        self.init(window: window)
        window.contentView = Self.makeContentView(in: window)
    }

    // MARK: Public API

    /// Present the sheet attached to `parentWindow`, or as a standalone
    /// window if `parentWindow` is nil.
    func present(relativeTo parentWindow: NSWindow? = nil) {
        guard let window else { return }
        if let parent = parentWindow {
            parent.beginSheet(window) { _ in }
        } else {
            showWindow(nil)
            window.center()
        }
    }

    /// Dismiss the sheet / window.
    @objc func close(_ sender: Any? = nil) {
        guard let window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: .cancel)
        } else {
            window.close()
        }
    }

    // MARK: - Window Factory

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        return window
    }

    // MARK: - Content View Factory

    private static func makeContentView(in window: NSWindow) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))

        // ── Scroll view ───────────────────────────────────────────────────
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        textView.textStorage?.setAttributedString(buildAttributedString())

        // Size the text view to fit content
        textView.sizeToFit()

        scrollView.documentView = textView

        // ── Close button ──────────────────────────────────────────────────
        let closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.title = "Close"
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}" // Escape
        // Wire action via target/action; target will be set after init
        closeButton.target = nil // resolved via responder chain
        closeButton.action = #selector(KeyboardShortcutsSheet.close(_:))

        // ── Separator ─────────────────────────────────────────────────────
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        root.addSubview(scrollView)
        root.addSubview(separator)
        root.addSubview(closeButton)

        // ── Layout ────────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            // scroll view fills top portion
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            // horizontal separator above button bar
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -8),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // Close button — bottom-right
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        // Let the text view stretch to the scroll view width
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        return root
    }

    // MARK: - Attributed String Builder

    private static func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()

        // ── Shared styles ─────────────────────────────────────────────────
        let titleFont    = NSFont.boldSystemFont(ofSize: 13)
        let keyFont      = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let descFont     = NSFont.systemFont(ofSize: 12)
        let headerColor  = NSColor.secondaryLabelColor
        let keyColor     = NSColor.labelColor
        let descColor    = NSColor.secondaryLabelColor

        // Column widths (monospaced chars ~7.2 pt wide at size 12)
        // We use a tab stop to align the description column.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: 190)
        ]
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 2

        let headerParagraphStyle = NSMutableParagraphStyle()
        headerParagraphStyle.paragraphSpacingBefore = 14
        headerParagraphStyle.paragraphSpacing = 4

        // ── Helper closures ───────────────────────────────────────────────

        /// Append a section header line.
        func appendHeader(_ title: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: headerColor,
                .paragraphStyle: headerParagraphStyle,
            ]
            result.append(NSAttributedString(string: "  \(title)\n", attributes: attrs))

            // Thin rule drawn as a string of em-dashes
            let ruleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: {
                    let s = NSMutableParagraphStyle()
                    s.paragraphSpacing = 4
                    return s
                }(),
            ]
            let ruleLine = String(repeating: "\u{2013}", count: 55) + "\n"
            result.append(NSAttributedString(string: "  \(ruleLine)", attributes: ruleAttrs))
        }

        /// Append a single shortcut row: `key  \t  description`.
        func appendRow(key: String, description: String) {
            let row = NSMutableAttributedString()

            // Leading padding
            row.append(NSAttributedString(string: "  ", attributes: [.font: keyFont]))

            // Key badge
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: keyFont,
                .foregroundColor: keyColor,
                .paragraphStyle: paragraphStyle,
            ]
            row.append(NSAttributedString(string: key, attributes: keyAttrs))

            // Tab + description
            let descAttrs: [NSAttributedString.Key: Any] = [
                .font: descFont,
                .foregroundColor: descColor,
                .paragraphStyle: paragraphStyle,
            ]
            row.append(NSAttributedString(string: "\t\(description)\n", attributes: descAttrs))

            result.append(row)
        }

        // ── Sections ──────────────────────────────────────────────────────

        // Top padding
        result.append(NSAttributedString(string: "\n", attributes: [.font: descFont]))

        // NAVIGATION
        appendHeader("NAVIGATION")
        appendRow(key: "← →",              description: "Previous / Next photo")
        appendRow(key: "Enter / Space",    description: "Open in Detail view")
        appendRow(key: "Escape",           description: "Back to grid")
        appendRow(key: "⌘O",              description: "Open folder")

        // RATING
        appendHeader("RATING")
        appendRow(key: "1  2  3  4  5",   description: "Set star rating 1–5")
        appendRow(key: "0",               description: "Clear rating")

        // FLAGGING
        appendHeader("FLAGGING")
        appendRow(key: "P",               description: "Pick")
        appendRow(key: "X",               description: "Reject")
        appendRow(key: "U",               description: "Unflagged (clear flag)")

        // COLOR LABELS
        appendHeader("COLOR LABELS")
        appendRow(key: "6",               description: "Red")
        appendRow(key: "7",               description: "Yellow")
        appendRow(key: "8",               description: "Green")
        appendRow(key: "9",               description: "Blue")

        // GRID VIEW
        appendHeader("GRID VIEW")
        appendRow(key: "⌘A",             description: "Select all")
        appendRow(key: "Arrow keys",      description: "Move selection")
        appendRow(key: "± or Slider",     description: "Resize thumbnails")

        // DETAIL VIEW
        appendHeader("DETAIL VIEW")
        appendRow(key: "Z",               description: "Toggle zoom (Fit ↔ 100%)")
        appendRow(key: "C",               description: "Enter / exit crop mode")

        // CROP MODE
        appendHeader("CROP MODE")
        appendRow(key: "F",               description: "Free aspect")
        appendRow(key: "1",               description: "1:1 square")
        appendRow(key: "2",               description: "4:5 portrait")
        appendRow(key: "3",               description: "16:9 wide")
        appendRow(key: "0",               description: "Original aspect")
        appendRow(key: "Return",          description: "Confirm crop")
        appendRow(key: "Escape",          description: "Cancel crop")

        // EXPORT
        appendHeader("EXPORT")
        appendRow(key: "⌘R",             description: "Reveal in Finder")
        appendRow(key: "⌘E",             description: "Copy picks to folder")
        appendRow(key: "⌘⇧O",           description: "Open picks with app")

        // GENERAL
        appendHeader("GENERAL")
        appendRow(key: "?",               description: "Show this help sheet")

        // Bottom padding
        result.append(NSAttributedString(string: "\n", attributes: [.font: descFont]))

        return result
    }
}
