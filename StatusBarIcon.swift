import AppKit

enum AppshotStatusIcon { case ready, success, warning, replay, recording }

@MainActor func appshotStatusImage(_ status: AppshotStatusIcon = .ready) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let frame = NSBezierPath()
        frame.lineWidth = 1.5
        frame.lineCapStyle = .round
        frame.lineJoinStyle = .round
        for points in [
            [NSPoint(x: 1.5, y: 12.5), NSPoint(x: 1.5, y: 16.5), NSPoint(x: 5.5, y: 16.5)],
            [NSPoint(x: 12.5, y: 16.5), NSPoint(x: 16.5, y: 16.5), NSPoint(x: 16.5, y: 12.5)],
            [NSPoint(x: 1.5, y: 5.5), NSPoint(x: 1.5, y: 1.5), NSPoint(x: 5.5, y: 1.5)],
            [NSPoint(x: 12.5, y: 1.5), NSPoint(x: 16.5, y: 1.5), NSPoint(x: 16.5, y: 5.5)],
        ] {
            frame.move(to: points[0])
            frame.line(to: points[1])
            frame.line(to: points[2])
        }
        frame.stroke()
        let bubble = NSBezierPath()
        bubble.lineWidth = 1.35
        bubble.lineJoinStyle = .round
        bubble.move(to: NSPoint(x: 6, y: 12.5))
        bubble.line(to: NSPoint(x: 12, y: 12.5))
        bubble.curve(to: NSPoint(x: 13.5, y: 11), controlPoint1: NSPoint(x: 13, y: 12.5), controlPoint2: NSPoint(x: 13.5, y: 12))
        bubble.line(to: NSPoint(x: 13.5, y: 8))
        bubble.curve(to: NSPoint(x: 12, y: 6.5), controlPoint1: NSPoint(x: 13.5, y: 7), controlPoint2: NSPoint(x: 13, y: 6.5))
        bubble.line(to: NSPoint(x: 8.5, y: 6.5))
        bubble.line(to: NSPoint(x: 6, y: 4.5))
        bubble.line(to: NSPoint(x: 6, y: 6.5))
        bubble.curve(to: NSPoint(x: 4.5, y: 8), controlPoint1: NSPoint(x: 5, y: 6.5), controlPoint2: NSPoint(x: 4.5, y: 7))
        bubble.line(to: NSPoint(x: 4.5, y: 11))
        bubble.curve(to: NSPoint(x: 6, y: 12.5), controlPoint1: NSPoint(x: 4.5, y: 12), controlPoint2: NSPoint(x: 5, y: 12.5))
        bubble.close()
        bubble.stroke()
        if status == .success { NSBezierPath(ovalIn: NSRect(x: 14.5, y: 0.5, width: 3, height: 3)).fill() }
        if status == .recording { NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12.5, width: 5.5, height: 5.5)).fill() }
        if status == .replay {
            let ring = NSBezierPath(ovalIn: NSRect(x: 13.25, y: 13.25, width: 4, height: 4))
            ring.lineWidth = 1.2
            ring.stroke()
        }
        if status == .warning {
            let mark = NSBezierPath()
            mark.lineWidth = 1.5
            mark.lineCapStyle = .round
            mark.move(to: NSPoint(x: 9, y: 10.7))
            mark.line(to: NSPoint(x: 9, y: 9.1))
            mark.stroke()
            NSBezierPath(ovalIn: NSRect(x: 8.4, y: 7.5, width: 1.2, height: 1.2)).fill()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Capture Studio — capture and compose"
    return image
}
