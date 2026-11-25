import CoreGraphics

/// Picks where the text cursor is from what an app reported through
/// Accessibility. Apps get this wrong in different ways: Chrome answers
/// `AXBoundsForRange` with junk in web text areas but gets the text-marker
/// version right (and the reverse in plain text fields), and some native
/// apps put the caret at the field's right edge at the start of a line.
///
/// All rectangles are in Accessibility coordinates: points, origin at the
/// top left of the main screen, y growing downwards.
public enum CaretGeometry {
    /// How far outside the text element a reported caret may be.
    static let slack: CGFloat = 4

    /// - Parameters:
    ///   - rangeBounds: `AXBoundsForRange` of an empty range at the caret.
    ///   - markerBounds: `AXBoundsForTextMarkerRange` of the selection
    ///     (Chrome and WebKit).
    ///   - element: the focused text element's frame.
    ///   - location: the caret's character index.
    /// - Returns: the caret's rectangle, or nil when nothing is known (use
    ///   the mouse pointer). Falls back to the element's left edge, as tall
    ///   as the element, when the app gave no usable caret.
    public static func caret(rangeBounds: CGRect?, markerBounds: CGRect?, element: CGRect?, location: Int) -> CGRect? {
        if var rect = usable(rangeBounds, in: element) {
            // Mimestream, at the start of a new line: the right line, but
            // the right-hand edge of the field.
            if let element, location > 0, rect.minX >= element.maxX - slack {
                rect.origin.x = element.minX
            }
            return rect
        }
        if var rect = usable(markerBounds, in: element) {
            // Chrome, at the start of a new line: the whole line.
            if let element, rect.width >= element.width * 0.8 {
                rect.size.width = 0
            }
            return rect
        }
        if let element {
            return CGRect(x: element.minX, y: element.minY, width: 0, height: element.height)
        }
        return nil
    }

    private static func usable(_ rect: CGRect?, in element: CGRect?) -> CGRect? {
        guard let rect, rect.height > 0 else { return nil }
        guard let element else { return rect }
        return element.insetBy(dx: -slack, dy: -slack).contains(rect.origin) ? rect : nil
    }
}
