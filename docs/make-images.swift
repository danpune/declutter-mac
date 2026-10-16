import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draws the README's pictures from scratch, so no screenshot (and nothing personal) ever lands in the repo:
//   docs/demo.gif  a cluttered desktop clearing into the Dock with one click, then coming back
//   docs/menu.png  DeClutter's right-click menu
// Run from the repo root: swift docs/make-images.swift

let W: CGFloat = 800, H: CGFloat = 500
let green = NSColor(red: 0.16, green: 0.71, blue: 0.36, alpha: 1)

// MARK: drawing helpers (top-left origin everywhere)

func render(_ size: CGSize, scale: CGFloat = 1, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func image(_ img: CGImage, in r: CGRect, _ ctx: CGContext, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: r.minX, y: r.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
    ctx.restoreGState()
}

func fill(_ r: CGRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
}

func symbol(_ name: String, in r: CGRect, color: NSColor, weight: NSFont.Weight = .semibold) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: r.height, weight: weight).applying(.init(paletteColors: [color]))) else { return }
    let s = img.size, k = min(r.width / s.width, r.height / s.height)
    let fit = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
    img.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func ease(_ t: CGFloat) -> CGFloat { let t = max(0, min(1, t)); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

// MARK: the made-up desktop

struct App { let color: NSColor; let symbol: String }
let apps = [App(color: NSColor(red: 0.20, green: 0.47, blue: 0.96, alpha: 1), symbol: "globe"),
            App(color: NSColor(red: 0.12, green: 0.56, blue: 1.00, alpha: 1), symbol: "envelope.fill"),
            App(color: NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1), symbol: "message.fill"),
            App(color: NSColor(red: 1.00, green: 0.78, blue: 0.00, alpha: 1), symbol: "note.text"),
            App(color: NSColor(red: 1.00, green: 0.18, blue: 0.33, alpha: 1), symbol: "music.note"),
            App(color: NSColor(red: 0.19, green: 0.69, blue: 0.35, alpha: 1), symbol: "tablecells.fill"),
            App(color: NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1), symbol: "photo.fill"),
            App(color: NSColor(red: 0.11, green: 0.61, blue: 0.94, alpha: 1), symbol: "folder.fill")]

let iconSize: CGFloat = 42, iconGap: CGFloat = 9, separator: CGFloat = 18
let dockWidth = CGFloat(apps.count + 1) * iconSize + CGFloat(apps.count) * iconGap + separator + 24
let dockRect = CGRect(x: (W - dockWidth) / 2, y: H - 62, width: dockWidth, height: 56)
func iconRect(_ i: Int) -> CGRect {   // i == apps.count is DeClutter, after the separator
    let x = dockRect.minX + 12 + CGFloat(i) * (iconSize + iconGap) + (i == apps.count ? separator : 0)
    return CGRect(x: x, y: dockRect.minY + 7, width: iconSize, height: iconSize)
}
let menuIcon = CGRect(x: 586, y: 3, width: 18, height: 16)

enum Kind { case browser, mail, messages, notes, music, sheet }
struct Win { let frame: CGRect; let app: Int; let title: String; let kind: Kind }
let windows = [Win(frame: CGRect(x: 40, y: 300, width: 220, height: 104), app: 4, title: "Now Playing", kind: .music),
               Win(frame: CGRect(x: 60, y: 48, width: 420, height: 290), app: 0, title: "Weekend trip ideas", kind: .browser),
               Win(frame: CGRect(x: 520, y: 44, width: 250, height: 170), app: 0, title: "Flight prices", kind: .browser),
               Win(frame: CGRect(x: 330, y: 92, width: 350, height: 236), app: 1, title: "Inbox (248)", kind: .mail),
               Win(frame: CGRect(x: 120, y: 196, width: 240, height: 196), app: 3, title: "Groceries", kind: .notes),
               Win(frame: CGRect(x: 490, y: 186, width: 270, height: 214), app: 2, title: "Family", kind: .messages),
               Win(frame: CGRect(x: 250, y: 236, width: 300, height: 170), app: 5, title: "Budget 2026", kind: .sheet)]

let gray = NSColor(white: 0.86, alpha: 1), lightGray = NSColor(white: 0.93, alpha: 1)

func drawWindow(_ w: Win) -> CGImage {
    render(w.frame.size, scale: 2) { _ in
        let size = w.frame.size
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).addClip()
        fill(CGRect(origin: .zero, size: size), w.kind == .notes ? NSColor(red: 1, green: 0.98, blue: 0.86, alpha: 1) : .white)
        fill(CGRect(x: 0, y: 0, width: size.width, height: 26), NSColor(white: 0.95, alpha: 1))
        for (i, c) in [NSColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                       NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)].enumerated() {
            fill(CGRect(x: 10 + CGFloat(i) * 17, y: 8, width: 11, height: 11), c, radius: 5.5)
        }
        let tw = textWidth(w.title, size: 11, weight: .semibold)
        text(w.title, at: CGPoint(x: (size.width - tw) / 2, y: 6), size: 11, weight: .semibold, color: NSColor(white: 0.3, alpha: 1))
        let body = CGRect(x: 12, y: 36, width: size.width - 24, height: size.height - 48)
        switch w.kind {
        case .browser:
            fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: 16), lightGray, radius: 8)
            fill(CGRect(x: body.minX, y: body.minY + 26, width: body.width, height: body.height * 0.42), apps[w.app].color.withAlphaComponent(0.25), radius: 6)
            symbol("mountain.2.fill", in: CGRect(x: body.midX - 20, y: body.minY + 26 + body.height * 0.21 - 14, width: 40, height: 28), color: apps[w.app].color.withAlphaComponent(0.6))
            var y = body.minY + 34 + body.height * 0.42
            while y < body.maxY - 6 { fill(CGRect(x: body.minX, y: y, width: body.width * (y.truncatingRemainder(dividingBy: 3) < 1 ? 0.7 : 0.95), height: 7), gray, radius: 3.5); y += 15 }
        case .mail:
            var y = body.minY
            for i in 0..<6 where y + 30 < body.maxY {
                if i < 3 { fill(CGRect(x: body.minX, y: y + 5, width: 7, height: 7), apps[1].color, radius: 3.5) }
                fill(CGRect(x: body.minX + 14, y: y + 3, width: 90, height: 8), NSColor(white: 0.55, alpha: 1), radius: 4)
                fill(CGRect(x: body.minX + 14, y: y + 16, width: body.width - 30, height: 6), gray, radius: 3)
                y += 34
            }
        case .notes:
            for (i, item) in ["Milk", "Eggs", "Coffee", "Bread", "Tomatoes", "Call the plumber"].enumerated() {
                let y = body.minY + CGFloat(i) * 24
                guard y + 18 < body.maxY else { break }
                NSColor(white: 0.55, alpha: 1).setStroke()
                NSBezierPath(ovalIn: CGRect(x: body.minX, y: y + 3, width: 11, height: 11)).stroke()
                text(item, at: CGPoint(x: body.minX + 18, y: y), size: 12, color: NSColor(white: 0.2, alpha: 1))
            }
        case .messages:
            var y = body.minY
            for (i, width) in [0.6, 0.45, 0.7, 0.5, 0.55].enumerated() where y + 24 < body.maxY {
                let mine = i % 2 == 1, bw = body.width * CGFloat(width)
                fill(CGRect(x: mine ? body.maxX - bw : body.minX, y: y, width: bw, height: 24), mine ? apps[0].color : lightGray, radius: 12)
                y += 34
            }
        case .music:
            fill(CGRect(x: body.minX, y: body.minY, width: 56, height: 56), apps[4].color.withAlphaComponent(0.8), radius: 6)
            symbol("music.note", in: CGRect(x: body.minX + 14, y: body.minY + 14, width: 28, height: 28), color: .white)
            fill(CGRect(x: body.minX + 68, y: body.minY + 8, width: 110, height: 9), NSColor(white: 0.4, alpha: 1), radius: 4.5)
            fill(CGRect(x: body.minX + 68, y: body.minY + 24, width: 80, height: 7), gray, radius: 3.5)
            fill(CGRect(x: body.minX + 68, y: body.minY + 44, width: body.width - 68, height: 4), gray, radius: 2)
            fill(CGRect(x: body.minX + 68, y: body.minY + 44, width: (body.width - 68) * 0.4, height: 4), apps[4].color, radius: 2)
        case .sheet:
            fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: 18), apps[5].color.withAlphaComponent(0.25))
            NSColor(white: 0.85, alpha: 1).setFill()
            for row in 0...6 { NSRect(x: body.minX, y: body.minY + CGFloat(row) * 18, width: body.width, height: 1).fill() }
            for col in 0...4 { NSRect(x: body.minX + CGFloat(col) * body.width / 4, y: body.minY, width: 1, height: 108).fill() }
            for row in 1...5 { for col in 1...3 {
                text("\((row * 37 + col * 53) % 900 + 100)", at: CGPoint(x: body.minX + CGFloat(col) * body.width / 4 + 6, y: body.minY + CGFloat(row) * 18 + 2), size: 10, color: NSColor(white: 0.35, alpha: 1))
            } }
        }
    }
}
let windowImages = windows.map(drawWindow)

// One frame. progress: 0 = every window open, 1 = all in the Dock.
struct Frame {
    var progress: CGFloat = 0
    var cursor: CGPoint? = nil
    var ripple: CGFloat? = nil
    var caption = ""
    var keys = false
    var delay: Double = 0.06
}

func drawFrame(_ f: Frame) -> CGImage {
    render(CGSize(width: W, height: H)) { ctx in
        // Wallpaper: flat bands, which a GIF keeps crisp (gradients band).
        fill(CGRect(x: 0, y: 0, width: W, height: H), NSColor(red: 0.62, green: 0.80, blue: 0.93, alpha: 1))
        NSColor(red: 0.50, green: 0.72, blue: 0.89, alpha: 1).setFill()
        let hill = NSBezierPath(); hill.move(to: CGPoint(x: 0, y: 330)); hill.curve(to: CGPoint(x: W, y: 300), controlPoint1: CGPoint(x: 260, y: 230), controlPoint2: CGPoint(x: 520, y: 400)); hill.line(to: CGPoint(x: W, y: H)); hill.line(to: CGPoint(x: 0, y: H)); hill.fill()
        NSColor(red: 0.39, green: 0.63, blue: 0.84, alpha: 1).setFill()
        let hill2 = NSBezierPath(); hill2.move(to: CGPoint(x: 0, y: 420)); hill2.curve(to: CGPoint(x: W, y: 390), controlPoint1: CGPoint(x: 300, y: 360), controlPoint2: CGPoint(x: 560, y: 450)); hill2.line(to: CGPoint(x: W, y: H)); hill2.line(to: CGPoint(x: 0, y: H)); hill2.fill()

        // Windows, each shrinking toward its app's Dock icon (narrowing faster than it shortens, like macOS's Scale effect).
        for (i, w) in windows.enumerated() {
            let p = ease(f.progress * 1.12 - CGFloat(i) * 0.02)
            guard p < 0.999 else { continue }
            let target = iconRect(w.app)
            let wPos = ease(min(1, p * 1.25))
            let r = CGRect(x: lerp(w.frame.minX, target.midX - 6, p), y: lerp(w.frame.minY, target.midY - 4, p * p),
                           width: lerp(w.frame.width, 12, wPos), height: lerp(w.frame.height, 8, p))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: NSColor(white: 0, alpha: 0.22 * (1 - p)).cgColor)
            image(windowImages[i], in: r, ctx, alpha: p > 0.8 ? (1 - p) / 0.2 : 1)
            ctx.restoreGState()
        }

        // Menu bar, with DeClutter's icon (it turns into a ↩︎ arrow while the screen is clear, as in the app).
        fill(CGRect(x: 0, y: 0, width: W, height: 22), NSColor(white: 1, alpha: 0.82))
        text("Browser", at: CGPoint(x: 14, y: 3), size: 13, weight: .bold)
        var x: CGFloat = 80
        for item in ["File", "Edit", "View", "Window", "Help"] { text(item, at: CGPoint(x: x, y: 3), size: 13); x += textWidth(item, size: 13) + 18 }
        if f.ripple != nil { fill(menuIcon.insetBy(dx: -4, dy: -1), NSColor(white: 0, alpha: 0.12), radius: 4) }
        symbol(f.progress > 0.5 ? "arrow.uturn.backward.circle" : "macwindow.on.rectangle", in: menuIcon, color: green)
        symbol("wifi", in: CGRect(x: 618, y: 4, width: 16, height: 14), color: .black)
        symbol("battery.75percent", in: CGRect(x: 644, y: 4, width: 26, height: 14), color: .black)
        text("Thu 9:41 AM", at: CGPoint(x: 686, y: 3), size: 13)

        // Dock: running-app dots stay put; DeClutter last, after the separator.
        fill(dockRect, NSColor(white: 1, alpha: 0.5), radius: 16)
        for i in 0...apps.count {
            let r = iconRect(i)
            if i == apps.count {
                NSGradient(starting: NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1), ending: NSColor(red: 0.08, green: 0.55, blue: 0.27, alpha: 1))!
                    .draw(in: NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10), angle: 90)   // 90, not -90: this context is flipped
                symbol("macwindow.on.rectangle", in: r.insetBy(dx: 9, dy: 11), color: .white)
            } else {
                fill(r, apps[i].color, radius: 10)
                symbol(apps[i].symbol, in: r.insetBy(dx: 10, dy: 10), color: .white)
            }
            fill(CGRect(x: r.midX - 2, y: dockRect.maxY - 6, width: 4, height: 4), NSColor(white: 0.25, alpha: 1), radius: 2)
        }
        NSColor(white: 0.4, alpha: 0.5).setFill()
        NSRect(x: iconRect(apps.count).minX - separator / 2 - 4, y: dockRect.minY + 10, width: 1, height: dockRect.height - 20).fill()

        // The shortcut, shown as keycaps.
        if f.keys {
            let keys = ["⌃", "⌥", "D"], kw: CGFloat = 56, gap: CGFloat = 10
            let start = (W - CGFloat(keys.count) * kw - CGFloat(keys.count - 1) * gap) / 2
            fill(CGRect(x: start - 18, y: 196, width: CGFloat(keys.count) * (kw + gap) + 26, height: 92), NSColor(white: 0, alpha: 0.55), radius: 18)
            for (i, k) in keys.enumerated() {
                let r = CGRect(x: start + CGFloat(i) * (kw + gap), y: 214, width: kw, height: 56)
                fill(r, .white, radius: 10)
                let w = textWidth(k, size: 26, weight: .medium)
                text(k, at: CGPoint(x: r.midX - w / 2, y: r.minY + 11), size: 26, weight: .medium, color: NSColor(white: 0.2, alpha: 1))
            }
        }

        // Cursor and click ripple.
        if let c = f.cursor {
            if let rp = f.ripple {
                NSColor(white: 0, alpha: 0.35 * (1 - rp)).setStroke()
                let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 6 - 14 * rp, y: c.y - 6 - 14 * rp, width: 12 + 28 * rp, height: 12 + 28 * rp))
                ring.lineWidth = 2.5; ring.stroke()
            }
            let arrow = NSBezierPath()
            for (dx, dy) in [(0.0, 0.0), (0.0, 17.0), (4.5, 13.0), (8.0, 20.0), (10.5, 19.0), (7.0, 12.0), (12.5, 12.0)] { let p = CGPoint(x: c.x + dx, y: c.y + dy); arrow.elementCount == 0 ? arrow.move(to: p) : arrow.line(to: p) }
            arrow.close()
            NSColor.black.setFill(); arrow.fill()
            NSColor.white.setStroke(); arrow.lineWidth = 1.2; arrow.stroke()
        }

        // Caption, at the top, so it never hides windows landing in the Dock.
        if !f.caption.isEmpty {
            let tw = textWidth(f.caption, size: 19, weight: .semibold)
            fill(CGRect(x: (W - tw) / 2 - 18, y: 34, width: tw + 36, height: 38), NSColor(white: 0.08, alpha: 0.78), radius: 19)
            text(f.caption, at: CGPoint(x: (W - tw) / 2, y: 42), size: 19, weight: .semibold, color: .white)
        }
    }
}

// MARK: the story

var frames: [Frame] = []
let home = CGPoint(x: 420, y: 270), onIcon = CGPoint(x: menuIcon.midX - 1, y: menuIcon.midY - 2)
frames.append(Frame(cursor: home, caption: "Too many windows open?", delay: 1.8))
for i in 1...10 {
    let t = ease(CGFloat(i) / 10)
    frames.append(Frame(cursor: CGPoint(x: lerp(home.x, onIcon.x, t), y: lerp(home.y, onIcon.y, t)), caption: "Click DeClutter in the menu bar or the Dock…"))
}
for i in 0..<4 { frames.append(Frame(cursor: onIcon, ripple: CGFloat(i) / 4, caption: "Click DeClutter in the menu bar or the Dock…")) }
for i in 1...20 { frames.append(Frame(progress: CGFloat(i) / 20, cursor: onIcon, caption: "…and every window shrinks into its Dock icon.", delay: 0.04)) }
frames.append(Frame(progress: 1, cursor: onIcon, caption: "A clean desktop. Nothing closed, nothing lost.", delay: 2.0))
frames.append(Frame(progress: 1, caption: "Click again, or press your shortcut…", keys: true, delay: 1.2))
for i in 1...20 { frames.append(Frame(progress: 1 - CGFloat(i) / 20, caption: "…and everything comes back, right where it was.", delay: 0.04)) }
frames.append(Frame(caption: "…and everything comes back, right where it was.", delay: 2.2))

let gifURL = URL(fileURLWithPath: "docs/demo.gif")
let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in frames {
    CGImageDestinationAddImage(gif, drawFrame(f), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: f.delay,
                                                                                  kCGImagePropertyGIFUnclampedDelayTime: f.delay]] as CFDictionary)
}
CGImageDestinationFinalize(gif)

// MARK: the menu

let menuItems: [(String, String, Bool)] = [   // title, shortcut, ticked; "-" is a separator
    ("Declutter", "⌃⌥D", false), ("Restore Everything", "", false), ("-", "", false),
    ("Quit Menu Bar Apps…", "", false), ("Arrange Menu Bar…", "", false), ("-", "", false),
    ("Never Hide or Quit", "›", false), ("Change Shortcut…", "", false), ("Animate", "", true),
    ("Show in Dock", "", true), ("Open at Login", "", true), ("-", "", false),
    ("Version 1.2 · What's New", "", false), ("-", "", false), ("Quit DeClutter", "⌘Q", false)]
let rowH: CGFloat = 23, sepH: CGFloat = 11, menuW: CGFloat = 250
let menuH = menuItems.reduce(CGFloat(12)) { $0 + ($1.0 == "-" ? sepH : rowH) }
let menuSize = CGSize(width: menuW + 60, height: menuH + 60)
let menu = render(menuSize, scale: 2) { ctx in
    fill(CGRect(origin: .zero, size: menuSize), NSColor(red: 0.62, green: 0.80, blue: 0.93, alpha: 1))
    fill(CGRect(x: 0, y: 0, width: menuSize.width, height: 24), NSColor(white: 1, alpha: 0.82))
    let icon = CGRect(x: 40, y: 4, width: 18, height: 16)
    fill(icon.insetBy(dx: -5, dy: -2), NSColor(white: 0, alpha: 0.12), radius: 4)
    symbol("macwindow.on.rectangle", in: icon, color: green)
    symbol("wifi", in: CGRect(x: 76, y: 5, width: 16, height: 14), color: .black)
    text("Thu 9:41 AM", at: CGPoint(x: 104, y: 4), size: 13)
    let box = CGRect(x: 30, y: 30, width: menuW, height: menuH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor(white: 0, alpha: 0.3).cgColor)
    fill(box, NSColor(white: 0.97, alpha: 1), radius: 9)
    ctx.restoreGState()
    var y = box.minY + 6
    for (i, (title, key, ticked)) in menuItems.enumerated() {
        if title == "-" { fill(CGRect(x: box.minX + 10, y: y + 5, width: box.width - 20, height: 1), NSColor(white: 0.82, alpha: 1)); y += sepH; continue }
        let selected = i == 0
        if selected { fill(CGRect(x: box.minX + 5, y: y, width: box.width - 10, height: rowH), NSColor(red: 0.04, green: 0.47, blue: 0.98, alpha: 1), radius: 5) }
        let color: NSColor = selected ? .white : NSColor(white: 0.1, alpha: 1)
        if ticked { text("✓", at: CGPoint(x: box.minX + 11, y: y + 3), size: 13, weight: .semibold, color: color) }
        text(title, at: CGPoint(x: box.minX + 28, y: y + 3), size: 13, color: color)
        if !key.isEmpty { text(key, at: CGPoint(x: box.maxX - 16 - textWidth(key, size: 13), y: y + 3), size: 13, color: selected ? .white : NSColor(white: 0.45, alpha: 1)) }
        y += rowH
    }
}
let png = NSBitmapImageRep(cgImage: menu).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "docs/menu.png"))
print("wrote docs/demo.gif (\(frames.count) frames) and docs/menu.png")

// MARK: the link preview (GitHub → Settings → Social preview), shown when the repo link is shared in Messages or WhatsApp

let socialSize = CGSize(width: 1280, height: 640)
let before = drawFrame(Frame()), after = drawFrame(Frame(progress: 1))
let social = render(socialSize) { ctx in
    fill(CGRect(origin: .zero, size: socialSize), NSColor(red: 0.95, green: 0.98, blue: 0.96, alpha: 1))
    let tile = CGRect(x: 80, y: 96, width: 120, height: 120)
    NSGradient(starting: NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1), ending: NSColor(red: 0.08, green: 0.55, blue: 0.27, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 27, yRadius: 27), angle: 90)   // 90, not -90: this context is flipped
    symbol("macwindow.on.rectangle", in: tile.insetBy(dx: 24, dy: 30), color: .white)
    text("DeClutter", at: CGPoint(x: 76, y: 236), size: 84, weight: .bold, color: NSColor(white: 0.1, alpha: 1))
    text("Too many windows open?", at: CGPoint(x: 80, y: 352), size: 34, weight: .semibold, color: green)
    text("One click tucks them all into the Dock.", at: CGPoint(x: 80, y: 400), size: 30, color: NSColor(white: 0.3, alpha: 1))
    text("One more brings them all back.", at: CGPoint(x: 80, y: 440), size: 30, color: NSColor(white: 0.3, alpha: 1))
    text("Free for Mac", at: CGPoint(x: 80, y: 528), size: 24, weight: .semibold, color: NSColor(white: 0.45, alpha: 1))
    // Before and after, with an arrow between.
    for (img, y) in [(before, CGFloat(56)), (after, CGFloat(344))] {
        let r = CGRect(x: 760, y: y, width: 432, height: 270)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: NSColor(white: 0, alpha: 0.25).cgColor)
        fill(r, .white, radius: 14)
        ctx.restoreGState()
        ctx.saveGState()
        NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).addClip()
        image(img, in: r, ctx)
        ctx.restoreGState()
    }
    fill(CGRect(x: 948, y: 316, width: 56, height: 40), green, radius: 20)
    symbol("arrow.down", in: CGRect(x: 960, y: 322, width: 32, height: 28), color: .white, weight: .bold)
}
try! NSBitmapImageRep(cgImage: social).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/social.png"))
print("wrote docs/social.png")
