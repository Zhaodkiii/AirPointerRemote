import AppKit

let width = 640
let height = 390
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

func color(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

func centered(_ text: String, fromTop top: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: UInt32) {
    let label = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(ink)
    ])
    let dimensions = label.size()
    label.draw(at: CGPoint(x: (CGFloat(width) - dimensions.width) / 2,
                           y: CGFloat(height) - top - dimensions.height))
}

func rounded(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: CGRect(x: x, y: CGFloat(height) - top - h, width: w, height: h),
                 xRadius: radius, yRadius: radius)
}

let frame = CGRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: color(0x142440), ending: color(0x090F20))!.draw(in: frame, angle: -90)
centered("Install AirPointer Remote", fromTop: 36, size: 29, weight: .bold, ink: 0xFFFFFF)
centered("Drag AirPointer Remote into Applications.", fromTop: 80, size: 16, weight: .medium, ink: 0xD6E4FF)

for x in [CGFloat(80), 376] {
    let card = rounded(x, 133, 184, 143, radius: 20)
    color(0x17243C).setFill()
    card.fill()
    color(0x34496B).setStroke()
    card.lineWidth = 1
    card.stroke()
}

let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: 290, y: 194))
arrow.line(to: CGPoint(x: 350, y: 194))
arrow.move(to: CGPoint(x: 335, y: 209))
arrow.line(to: CGPoint(x: 350, y: 194))
arrow.line(to: CGPoint(x: 335, y: 179))
color(0x7FADFF).setStroke()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

centered("Then open it from Applications.", fromTop: 306, size: 15, weight: .semibold, ink: 0xFFFFFF)
centered("Look for the AirPointer icon in your menu bar.", fromTop: 331, size: 13, weight: .regular, ink: 0xB3C5E7)

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
