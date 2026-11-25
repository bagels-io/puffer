import AppKit
import ApplicationServices
import PufferCore

/// Asks the frontmost app, through Accessibility, where its text cursor is.
/// Main thread only: these calls can wait on the other app, so they must
/// never run on the event tap's thread.
@MainActor
enum CaretLocator {
    /// Chromium browsers build the accessibility tree for web pages only
    /// once an assistive app asks for it.
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]
    /// Processes already asked to switch their tree on.
    private static var askedForAccessibility: Set<pid_t> = []

    /// The caret in Cocoa screen coordinates (origin bottom left of the main
    /// screen), or nil when the app gave nothing usable.
    static func caretRect() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        guard var rect = lookUp(in: appElement) else { return nil }
        if !rect.exact, rect.marker == nil,
           let id = app.bundleIdentifier, chromiumBrowsers.contains(id),
           !askedForAccessibility.contains(app.processIdentifier) {
            askedForAccessibility.insert(app.processIdentifier)
            // Not AXEnhancedUserInterface, which upsets window animation.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let retry = lookUp(in: appElement) { rect = retry }
        }
        return rect.caret.map(toCocoa)
    }

    private struct Found {
        var caret: CGRect?
        var marker: CGRect?
        /// The app reported the caret itself, not just the text field.
        var exact: Bool
    }

    private static func lookUp(in appElement: AXUIElement) -> Found? {
        // Apps sometimes answer "no value" for a moment; the system-wide
        // element often knows anyway.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        guard let focused: AXUIElement = value(appElement, kAXFocusedUIElementAttribute)
            ?? value(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.1)

        var location = 0
        var rangeBounds: CGRect?
        if let rangeValue: AXValue = value(focused, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                location = range.location
                var caret = CFRange(location: range.location, length: 0)
                if let caretValue = AXValueCreate(.cfRange, &caret) {
                    rangeBounds = rect(focused, kAXBoundsForRangeParameterizedAttribute, caretValue)
                }
            }
        }

        var markerBounds: CGRect?
        var markerRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
           let markerRange {
            markerBounds = rect(focused, "AXBoundsForTextMarkerRange", markerRange)
        }

        let element = frame(of: focused)
        let caret = CaretGeometry.caret(
            rangeBounds: rangeBounds, markerBounds: markerBounds,
            element: element, location: location
        )
        let fieldOnly = element.map { CGRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) }
        return Found(caret: caret, marker: markerBounds, exact: caret != nil && caret != fieldOnly)
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              let result else { return nil }
        // AXUIElement and AXValue are CF types: check before casting.
        if T.self == AXUIElement.self, CFGetTypeID(result) != AXUIElementGetTypeID() { return nil }
        if T.self == AXValue.self, CFGetTypeID(result) != AXValueGetTypeID() { return nil }
        return result as? T
    }

    private static func rect(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CGRect? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Accessibility measures from the top left of the main screen.
    static func toCocoa(_ rect: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// And back, for the event tap, which also measures from the top left.
    static func toTopLeft(_ rect: NSRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
