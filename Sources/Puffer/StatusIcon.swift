import AppKit

/// The menu bar icon: the pufferfish from the app icon, drawn as a template
/// image so macOS tints it for light and dark menu bars. It puffs up when
/// something expands (`StatusIconAnimator`).
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    /// - Parameter puff: 0 at rest, 1 fully puffed up.
    static func make(puff: CGFloat = 0) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(puff: puff)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Puffer"
        return image
    }

    /// Draws in an 18 × 18 point box, origin bottom left. Puffed up, the
    /// body and spikes grow and the fins move out with the body; it all
    /// still fits the box.
    static func draw(puff: CGFloat = 0) {
        let puff = min(max(puff, 0), 1)
        let center = NSPoint(x: 9, y: 8.6)
        let radius: CGFloat = 5.2 + 0.8 * puff

        NSColor.black.setFill()

        // Body.
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )).fill()

        // A few spikes above and below; the fins take the sides.
        for degrees in [50, 90, 130, 230, 270, 310] {
            let angle = CGFloat(degrees) * .pi / 180
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let across = CGVector(dx: -direction.dy, dy: direction.dx)
            let base = point(center, direction, radius - 0.5)
            let tip = point(center, direction, radius + 1.9 + 0.7 * puff)
            let spike = NSBezierPath()
            spike.move(to: point(base, across, 1.0))
            spike.line(to: tip)
            spike.line(to: point(base, across, -1.0))
            spike.close()
            spike.fill()
        }

        // Fins, one each side: a fan with two ribs cut into it.
        for side: CGFloat in [-1, 1] {
            let root = NSPoint(x: center.x + side * (radius - 1.2), y: center.y - 0.3)
            let facing: CGFloat = side > 0 ? 0 : 180
            let fin = NSBezierPath()
            fin.move(to: root)
            fin.appendArc(withCenter: root, radius: 4.2, startAngle: facing - 36, endAngle: facing + 36)
            fin.close()
            fin.fill()

            NSGraphicsContext.current?.compositingOperation = .clear
            for rib: CGFloat in [-12, 12] {
                let angle = (facing + rib) * .pi / 180
                let direction = CGVector(dx: cos(angle), dy: sin(angle))
                let line = NSBezierPath()
                // From the resting radius, so the ribs stay as long when puffed.
                line.move(to: point(root, direction, 5.2 - 3.6 + 1.6))
                line.line(to: point(root, direction, 4.5))
                line.lineWidth = 0.55
                NSColor.black.setStroke()
                line.stroke()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        // Eyes and smile, cut out of the body.
        NSGraphicsContext.current?.compositingOperation = .clear
        for x: CGFloat in [center.x - 2.1, center.x + 2.1] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.05, y: center.y + 0.35, width: 2.1, height: 2.3)).fill()
        }
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: center.x - 1.3, y: center.y - 1.2))
        smile.curve(
            to: NSPoint(x: center.x + 1.3, y: center.y - 1.2),
            controlPoint1: NSPoint(x: center.x - 0.9, y: center.y - 2.6),
            controlPoint2: NSPoint(x: center.x + 0.9, y: center.y - 2.6)
        )
        smile.lineWidth = 0.9
        smile.lineCapStyle = .round
        NSColor.black.setStroke()
        smile.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private static func point(_ start: NSPoint, _ direction: CGVector, _ distance: CGFloat) -> NSPoint {
        NSPoint(x: start.x + direction.dx * distance, y: start.y + direction.dy * distance)
    }
}
