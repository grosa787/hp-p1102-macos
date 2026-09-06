// Draws the app icon as a 1024x1024 PNG. Run by build.sh via `swift`.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Rounded-square background, macOS style (icon body is ~80% of the canvas).
let inset: CGFloat = S * 0.1
let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bg = CGPath(roundedRect: body, cornerWidth: S * 0.18, cornerHeight: S * 0.18, transform: nil)
ctx.addPath(bg); ctx.clip()
let colors = [NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.95, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.70, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// Two overlapping sheets.
func sheet(_ r: CGRect, label: String, fill: NSColor) {
    let p = CGPath(roundedRect: r, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(p); ctx.setFillColor(fill.cgColor); ctx.fillPath()
    ctx.restoreGState()
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: r.height * 0.5, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.08, green: 0.30, blue: 0.75, alpha: 1),
        .paragraphStyle: para]
    let tr = CGRect(x: r.minX, y: r.midY - r.height * 0.32, width: r.width, height: r.height * 0.65)
    (label as NSString).draw(in: tr, withAttributes: attrs)
}
let w = body.width * 0.46, h = w * 1.3
sheet(CGRect(x: body.midX - w * 0.78, y: body.midY - h * 0.35, width: w, height: h), label: "2",
      fill: NSColor(calibratedWhite: 0.92, alpha: 1))
sheet(CGRect(x: body.midX - w * 0.22, y: body.midY - h * 0.65, width: w, height: h), label: "1",
      fill: .white)

// Curved arrow suggesting "turn over".
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(S * 0.035); ctx.setLineCap(.round)
let c = CGPoint(x: body.midX + w * 0.62, y: body.midY + h * 0.42)
ctx.addArc(center: c, radius: S * 0.11, startAngle: .pi * 0.15, endAngle: .pi * 1.35, clockwise: false)
ctx.strokePath()
let tip = CGPoint(x: c.x + cos(.pi * 0.15) * S * 0.11, y: c.y + sin(.pi * 0.15) * S * 0.11)
ctx.move(to: CGPoint(x: tip.x - S * 0.05, y: tip.y + S * 0.01))
ctx.addLine(to: tip)
ctx.addLine(to: CGPoint(x: tip.x + S * 0.005, y: tip.y - S * 0.055))
ctx.strokePath()

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
