import AppKit

// Draws the 1024px app icon (white stacked windows on a green tile) to the PNG path given; build.sh turns it into AppIcon.icns.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { _ in
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1),
               ending: NSColor(red: 0.08, green: 0.55, blue: 0.27, alpha: 1))!.draw(in: tile, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold).applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    symbol.draw(in: NSRect(x: (1024 - symbol.size.width) / 2, y: (1024 - symbol.size.height) / 2,
                           width: symbol.size.width, height: symbol.size.height))
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
