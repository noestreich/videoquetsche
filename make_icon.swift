import Cocoa
import CoreGraphics

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let cx = s / 2
    let cy = s / 2

    // ── Rounded-rect clip ───────────────────────────────────────────────
    let r = s * 0.22
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // ── White background ────────────────────────────────────────────────
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // ── Teal sunburst rays ───────────────────────────────────────────────
    let teal = CGColor(red: 0.18, green: 0.68, blue: 0.72, alpha: 1)
    ctx.setFillColor(teal)
    let rayCount = 16
    let outerR = s * 0.85
    for i in 0 ..< rayCount where i % 2 == 0 {
        let a1 = CGFloat(i)     / CGFloat(rayCount) * 2 * .pi - .pi / 2
        let a2 = CGFloat(i + 1) / CGFloat(rayCount) * 2 * .pi - .pi / 2
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + cos(a1) * outerR, y: cy + sin(a1) * outerR))
        ctx.addLine(to: CGPoint(x: cx + cos(a2) * outerR, y: cy + sin(a2) * outerR))
        ctx.closePath()
        ctx.fillPath()
    }

    // ── Helper: filled rounded rect ─────────────────────────────────────
    func fillRR(_ rect: CGRect, _ cr: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: cr, cornerHeight: cr, transform: nil))
        ctx.fillPath()
    }

    // ── Dark teal fist ───────────────────────────────────────────────────
    let fistDark  = CGColor(red: 0.12, green: 0.38, blue: 0.44, alpha: 1)
    let fistMid   = CGColor(red: 0.16, green: 0.48, blue: 0.56, alpha: 1)

    // Palm body
    let palmW = s * 0.40
    let palmH = s * 0.30
    let palmX = cx - palmW / 2
    let palmY = cy - s * 0.02
    fillRR(CGRect(x: palmX, y: palmY, width: palmW, height: palmH), s * 0.06, fistDark)

    // Four knuckle bumps (fingers folded)
    let fingerW = s * 0.085
    let fingerH = s * 0.14
    let fingerY = palmY + palmH - s * 0.04
    let fingerCR = s * 0.04
    for i in 0 ..< 4 {
        let fx = palmX + CGFloat(i) * (palmW / 4) + (palmW / 4 - fingerW) / 2
        fillRR(CGRect(x: fx, y: fingerY, width: fingerW, height: fingerH), fingerCR, fistMid)
    }
    // Re-draw palm over bottom of fingers
    fillRR(CGRect(x: palmX, y: palmY, width: palmW, height: palmH - s * 0.02), s * 0.06, fistDark)

    // Thumb (left side, shorter)
    let thumbW = s * 0.09
    let thumbH = s * 0.10
    fillRR(CGRect(x: palmX - thumbW + s * 0.01,
                  y: palmY + palmH * 0.30,
                  width: thumbW, height: thumbH),
           s * 0.04, fistMid)

    // Arm / wrist below palm
    fillRR(CGRect(x: palmX + s * 0.04,
                  y: cy - s * 0.25,
                  width: palmW - s * 0.08,
                  height: s * 0.25),
           s * 0.04, fistDark)

    // ── Red crushed film strip ───────────────────────────────────────────
    let red = CGColor(red: 0.87, green: 0.15, blue: 0.12, alpha: 1)
    let redLight = CGColor(red: 1.0, green: 0.28, blue: 0.22, alpha: 1)

    // Main film body (horizontal, tilted slightly)
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy + s * 0.06)
    ctx.rotate(by: -0.18)
    let fw = s * 0.42
    let fh = s * 0.20
    fillRR(CGRect(x: -fw/2, y: -fh/2, width: fw, height: fh), s * 0.03, red)

    // Sprocket holes on film
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    let hSz = s * 0.035
    for i in 0 ..< 3 {
        let hx = -fw/2 + s * 0.04 + CGFloat(i) * (fw * 0.30)
        for hy in [-fh/2 + s * 0.025, fh/2 - s * 0.025 - hSz] {
            ctx.addPath(CGPath(roundedRect: CGRect(x: hx, y: hy, width: hSz, height: hSz),
                               cornerWidth: hSz * 0.3, cornerHeight: hSz * 0.3, transform: nil))
        }
    }
    ctx.fillPath()

    // Play triangle on film
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    let ts = s * 0.065
    ctx.move(to: CGPoint(x: -ts * 0.3, y: -ts * 0.85))
    ctx.addLine(to: CGPoint(x: ts * 0.9, y: 0))
    ctx.addLine(to: CGPoint(x: -ts * 0.3, y: ts * 0.85))
    ctx.closePath()
    ctx.fillPath()

    // Crack lines on film
    ctx.setStrokeColor(CGColor(red: 0.5, green: 0, blue: 0, alpha: 0.6))
    ctx.setLineWidth(s * 0.012)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: -fw * 0.05, y: -fh/2))
    ctx.addLine(to: CGPoint(x:  fw * 0.10, y:  fh/2))
    ctx.strokePath()
    ctx.move(to: CGPoint(x:  fw * 0.15, y: -fh/2))
    ctx.addLine(to: CGPoint(x: -fw * 0.05, y:  fh/2))
    ctx.strokePath()
    ctx.restoreGState()

    // ── Red debris / splatter pieces ─────────────────────────────────────
    struct Chip { var x,y,w,h,angle: CGFloat }
    let chips: [Chip] = [
        Chip(x: cx - s*0.32, y: cy + s*0.14, w: s*0.07, h: s*0.04, angle:  0.4),
        Chip(x: cx + s*0.26, y: cy + s*0.18, w: s*0.06, h: s*0.03, angle: -0.5),
        Chip(x: cx - s*0.30, y: cy - s*0.10, w: s*0.05, h: s*0.03, angle:  0.9),
        Chip(x: cx + s*0.20, y: cy - s*0.18, w: s*0.04, h: s*0.025, angle:-0.3),
        Chip(x: cx - s*0.08, y: cy + s*0.28, w: s*0.035, h: s*0.02, angle: 0.6),
        Chip(x: cx + s*0.30, y: cy - s*0.05, w: s*0.03, h: s*0.02, angle:-0.8),
    ]
    for chip in chips {
        ctx.saveGState()
        ctx.translateBy(x: chip.x + chip.w/2, y: chip.y + chip.h/2)
        ctx.rotate(by: chip.angle)
        fillRR(CGRect(x: -chip.w/2, y: -chip.h/2, width: chip.w, height: chip.h),
               chip.h * 0.3, (chips.firstIndex(where: { $0.x == chip.x })! % 2 == 0) ? red : redLight)
        ctx.restoreGState()
    }

    ctx.resetClip()
    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(Int, String)] = [
    (16,   "icon_16x16"),
    (32,   "icon_16x16@2x"),
    (32,   "icon_32x32"),
    (64,   "icon_32x32@2x"),
    (128,  "icon_128x128"),
    (256,  "icon_128x128@2x"),
    (256,  "icon_256x256"),
    (512,  "icon_256x256@2x"),
    (512,  "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetPath = CommandLine.arguments[1]
for (px, name) in sizes {
    let img = drawIcon(size: CGFloat(px))
    savePNG(img, to: "\(iconsetPath)/\(name).png")
    print("  ✓ \(name).png (\(px)px)")
}
print("done")
