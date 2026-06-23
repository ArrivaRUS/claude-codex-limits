// Renders the GitHub social-preview banner (1280x640) with CoreGraphics + CoreText.
// Same rendering path the app itself uses — no third-party dependencies.
// Usage: swift make-banner.swift <icon.png> <out.png>
import Foundation
import AppKit          // NSFont is toll-free bridged to CTFont (font objects only, no offscreen drawing)
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let iconPath = args.count > 1 ? args[1] : "Resources/appicon.png"
let outPath  = args.count > 2 ? args[2] : "docs/banner.png"

let W = 1280, H = 640
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}
let Wf = CGFloat(W), Hf = CGFloat(H)
func rgb(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
func sysFont(_ size: CGFloat,_ w: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: w) as CTFont }

// ---- background: vertical navy gradient (matches the app icon) ----
let bg = CGGradient(colorsSpace: cs, colors: [rgb(34,31,60), rgb(12,12,22), rgb(8,8,16)] as CFArray,
                    locations: [0, 0.65, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: Hf), end: CGPoint(x: 0, y: 0), options: [])

// ---- soft brand glows behind the icon (purple + blue, like the two rings) ----
let iconSize: CGFloat = 312
let iconRect = CGRect(x: 108, y: (Hf - iconSize)/2, width: iconSize, height: iconSize)
let ic = CGPoint(x: iconRect.midX, y: iconRect.midY)
ctx.setBlendMode(.screen)
let gPurple = CGGradient(colorsSpace: cs, colors: [rgb(150,86,255,0.50), rgb(150,86,255,0)] as CFArray, locations: [0,1])!
ctx.drawRadialGradient(gPurple, startCenter: ic, startRadius: 0, endCenter: ic, endRadius: 560, options: [])
let bc = CGPoint(x: iconRect.midX + 120, y: iconRect.midY - 70)
let gBlue = CGGradient(colorsSpace: cs, colors: [rgb(60,128,255,0.34), rgb(60,128,255,0)] as CFArray, locations: [0,1])!
ctx.drawRadialGradient(gBlue, startCenter: bc, startRadius: 0, endCenter: bc, endRadius: 460, options: [])
ctx.setBlendMode(.normal)

// ---- vignette to add depth ----
let vc = CGPoint(x: Wf/2, y: Hf/2)
let vig = CGGradient(colorsSpace: cs, colors: [rgb(0,0,0,0), rgb(0,0,0,0.42)] as CFArray, locations: [0.5,1])!
ctx.drawRadialGradient(vig, startCenter: vc, startRadius: 0, endCenter: vc, endRadius: 760,
                       options: [.drawsAfterEndLocation])

// ---- faint rounded card border ----
let border = CGPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: Wf-3, height: Hf-3),
                    cornerWidth: 30, cornerHeight: 30, transform: nil)
ctx.addPath(border); ctx.setStrokeColor(rgb(255,255,255,0.07)); ctx.setLineWidth(2); ctx.strokePath()

// ---- app icon with a soft drop shadow ----
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 55, color: rgb(0,0,0,0.6))
if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: iconPath) as CFURL, nil),
   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    ctx.draw(img, in: iconRect)
}
ctx.restoreGState()

// ---- text ----
let textX = iconRect.maxX + 76
let rightPad: CGFloat = 72
let maxTextW = Wf - textX - rightPad

func lineWidth(_ s: String,_ f: CTFont,_ kern: CGFloat) -> CGFloat {
    let l = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .kern: kern]))
    return CTLineGetTypographicBounds(l, nil, nil, nil)
}
func drawLine(_ s: String, x: CGFloat, baseline: CGFloat, font: CTFont, color: CGColor, kern: CGFloat = 0) {
    let l = CTLineCreateWithAttributedString(NSAttributedString(string: s,
            attributes: [.font: font, .foregroundColor: color, .kern: kern]))
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(l, ctx)
}
// glyph outlines -> for gradient-filled text
func glyphPath(_ s: String, font: CTFont, kern: CGFloat, at origin: CGPoint) -> CGPath {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .kern: kern]))
    let path = CGMutablePath()
    for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
        let n = CTRunGetGlyphCount(run)
        let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, n), &pos)
        for i in 0..<n {
            if let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                let t = CGAffineTransform(translationX: origin.x + pos[i].x, y: origin.y + pos[i].y)
                path.addPath(gp, transform: t)
            }
        }
    }
    return path
}
func drawGradientText(_ s: String, x: CGFloat, baseline: CGFloat, font: CTFont, kern: CGFloat, colors: [CGColor]) {
    let p = glyphPath(s, font: font, kern: kern, at: CGPoint(x: x, y: baseline))
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    let bb = p.boundingBoxOfPath
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: bb.minX, y: 0), end: CGPoint(x: bb.maxX, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// title — auto-fit
let title = "Claude Codex Limits"
var titleSize: CGFloat = 82
while titleSize > 44 && lineWidth(title, sysFont(titleSize, .bold), -0.5) > maxTextW { titleSize -= 1 }
drawLine(title, x: textX, baseline: 350, font: sysFont(titleSize, .bold), color: rgb(248,248,252), kern: -0.5)

// accent subtitle — purple→blue gradient (the two ring colors)
drawGradientText("Claude Code · Codex · live limits",
                 x: textX, baseline: 286, font: sysFont(30, .semibold), kern: 0.2,
                 colors: [rgb(196,134,255), rgb(120,150,255), rgb(86,158,255)])

// caption — muted gray
drawLine("macOS menu bar utility · native Swift · no telemetry",
         x: textX, baseline: 238, font: sysFont(21, .regular), color: rgb(156,156,172), kern: 0.3)

// ---- write PNG ----
guard let outImg = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else {
    fatalError("encode")
}
CGImageDestinationAddImage(dst, outImg, nil)
CGImageDestinationFinalize(dst)
print("wrote \(outPath) (\(W)x\(H))")
