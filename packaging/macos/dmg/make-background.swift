// Draws the DMG window background at 1x and 2x.
// Usage: swift make-background.swift <output directory>
// Then: tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
import AppKit

let width: CGFloat = 640, height: CGFloat = 400
// Icon centers match the Finder layout stored in DS_Store (top-left origin).
let appCenter = CGPoint(x: 180, y: 196), applicationsCenter = CGPoint(x: 460, y: 196)
let purple = NSColor(srgbRed: 0x57 / 255, green: 0x28 / 255, blue: 0x72 / 255, alpha: 1)
let pink = NSColor(srgbRed: 0xDD / 255, green: 0x45 / 255, blue: 0x7A / 255, alpha: 1)

struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
}

func pentagon(_ center: CGPoint, radius: CGFloat, rotation: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for index in 0..<5 {
        let angle = rotation + CGFloat(index) * 2 * .pi / 5
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        index == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

// The pattern fades out behind the icons.
func patternAlpha(_ y: CGFloat) -> CGFloat {
    let bottom = min(max((y - 292) / 70, 0), 1)
    let top = min(max((24 - y) / 24, 0), 1)
    return 0.07 + 0.83 * max(bottom, top * 0.5)
}

func drawMotif(at center: CGPoint, ring: Bool, random: inout Random) {
    let step: CGFloat = 6.4
    let offsets: [(CGFloat, CGFloat)] = ring
        ? [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        : [(-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5)]
    pink.withAlphaComponent(patternAlpha(center.y)).setFill()
    for (dx, dy) in offsets {
        let jitter = CGPoint(x: (random.next() - 0.5) * 0.8, y: (random.next() - 0.5) * 0.8)
        pentagon(CGPoint(x: center.x + dx * step + jitter.x, y: center.y + dy * step + jitter.y), radius: 2.5, rotation: random.next() * .pi).fill()
    }
}

func drawArrow() {
    pink.setFill()
    let y = appCenter.y, start = appCenter.x + 78, end = applicationsCenter.x - 92
    var random = Random(state: 7)
    let count = 7
    for index in 0..<count {
        let t = CGFloat(index) / CGFloat(count - 1)
        let x = start + (end - start) * t
        pentagon(CGPoint(x: x, y: y), radius: 1.8 + 1.4 * t, rotation: random.next() * .pi).fill()
    }
    let tip = CGPoint(x: end + 26, y: y)
    for index in 1...3 {
        let offset = CGFloat(index) * 7.5
        for sign in [-1.0, 1.0] as [CGFloat] {
            pentagon(CGPoint(x: tip.x - offset, y: y + sign * offset), radius: 3.2, rotation: random.next() * .pi).fill()
        }
    }
    pentagon(tip, radius: 3.6, rotation: 0.3).fill()
}

func render(scale: CGFloat, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    // Draw with a top-left origin so coordinates match Finder's icon positions.
    context.cgContext.translateBy(x: 0, y: height)
    context.cgContext.scaleBy(x: 1, y: -1)

    purple.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    var random = Random(state: 1911)
    let cell: CGFloat = 40
    for row in 0..<Int(height / cell) + 2 {
        for column in -1..<Int(width / cell) + 2 {
            let x = CGFloat(column) * cell + (row % 2 == 0 ? 0 : cell / 2) + 8
            let y = CGFloat(row) * cell + 6
            drawMotif(at: CGPoint(x: x, y: y), ring: (row + column) % 2 == 0, random: &random)
        }
    }

    pink.setFill()
    NSRect(x: 0, y: 0, width: 12, height: height).fill()
    NSRect(x: width - 12, y: 0, width: 12, height: height).fill()

    drawArrow()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try render(scale: 1, to: output.appendingPathComponent("background.png"))
try render(scale: 2, to: output.appendingPathComponent("background@2x.png"))
