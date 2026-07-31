// One-shot harness: render the weekly ring's calm vs. capped states through the
// REAL StatusRenderer, at the true 18 pt menu-bar size and enlarged, so the
// v0.12 opacity cue can be judged before the render goldens are regenerated.
//
//   swiftc -o /tmp/ring_preview tools/ring_preview.swift Sources/StatusRenderer.swift \
//          Sources/Providers.swift Sources/Forecast.swift && /tmp/ring_preview out.png
//
// Screen capture needs a permission this environment does not have; this draws
// the same pixels the menu bar would, minus its vibrancy.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ring_preview.png"

// The case the change exists for: pool at 82%, Fable at 98%. Only the alpha differs.
let cases: [(label: String, capped: Bool)] = [("calm (today)", false), ("capped (new)", true)]
let modes: [ColorMode] = [.brand, .thresholds, .monochrome, .accent, .heatmap]
let scales: [CGFloat] = [1, 4]

// Row 1 is the glyph at its true 18 pt. Row 2 is THE SAME 18 pt pixels magnified
// with interpolation off — re-rendering at 72 pt would show a ring the menu bar
// never draws, and the whole question is what 1.6 px of stroke can carry.
let magnify: CGFloat = 6
let rowH: CGFloat = 150, colW: CGFloat = 260
let size = NSSize(width: colW * CGFloat(modes.count) + 30, height: rowH + 60)

let img = NSImage(size: size)
img.lockFocus()
NSColor(white: 0.13, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

func label(_ s: String, _ p: NSPoint, _ c: NSColor, _ pt: CGFloat = 10) {
    (s as NSString).draw(at: p, withAttributes: [
        .font: NSFont.systemFont(ofSize: pt), .foregroundColor: c])
}

NSGraphicsContext.current?.imageInterpolation = .none
for (mi, mode) in modes.enumerated() {
    let x = 15 + CGFloat(mi) * colW
    label("\(mode)", NSPoint(x: x, y: size.height - 24), .white, 12)
    for (ci, c) in cases.enumerated() {
        let glyph = StatusRenderer.image(five: 15, week: 82, style: .concentric, mode: mode,
                                         height: 18, provider: .claude, weekCapped: c.capped)
        let gx = x + CGFloat(ci) * 122
        // True size, then the same pixels blown up.
        glyph.draw(at: NSPoint(x: gx + 40, y: size.height - 52),
                   from: .zero, operation: .sourceOver, fraction: 1)
        let box = NSRect(x: gx, y: size.height - 62 - glyph.size.height * magnify,
                         width: glyph.size.width * magnify, height: glyph.size.height * magnify)
        glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        label(c.label, NSPoint(x: gx, y: box.minY - 15), NSColor(white: 0.65, alpha: 1), 10)
    }
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
