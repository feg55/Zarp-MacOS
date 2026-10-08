#!/usr/bin/env swift
// Draws Zarp's app icon (and the GitHub social-preview image) from vector geometry, so the artwork
// is reproducible from this repository and sharp at every size instead of being a downscaled bitmap.
//
//   swift scripts/make-icon.swift appiconset App/Sources/Zarp/Assets.xcassets/AppIcon.appiconset
//   swift scripts/make-icon.swift png docs/images/icon.png 512
//   swift scripts/make-icon.swift social docs/images/social-preview.png
//   swift scripts/make-icon.swift dmg-background scripts/dmg
//
// `dmg-background` draws the window shown when the disk image is opened (background.png at 1x and
// background@2x.png at 2x; scripts/dmg/settings.py positions the icons on it, so the numbers below and
// there must agree).
//
// The lightning bolt is the outline of the Windows/Android Zarp icon (same author, MIT), set on the
// macOS icon grid: an 824 pt squircle centred in a 1024 pt canvas, which leaves the margin macOS
// expects for the drop shadow.
import AppKit

// The bolt, traced from the Windows icon on a 256 x 256 grid (y grows downwards there).
let bolt: [(CGFloat, CGFloat)] = [(143, 43), (135, 103), (183, 105), (105, 214), (121, 144), (74, 142)]
let boltCenter = CGPoint(x: 128.5, y: 128.5)
let boltHeight: CGFloat = 171

let orangeTop = NSColor(srgbRed: 255 / 255, green: 163 / 255, blue: 64 / 255, alpha: 1)
let orangeBottom = NSColor(srgbRed: 226 / 255, green: 108 / 255, blue: 16 / 255, alpha: 1)

/// A superellipse (|x|^n + |y|^n = 1, n = 5) is a close match for Apple's continuous-corner icon shape.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func boltPath(centeredAt center: CGPoint, height: CGFloat) -> CGPath {
    let k = height / boltHeight
    let path = CGMutablePath()
    for (i, p) in bolt.enumerated() {
        let pt = CGPoint(x: center.x + (p.0 - boltCenter.x) * k, y: center.y - (p.1 - boltCenter.y) * k)
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

/// Draws the icon into `ctx` (origin bottom-left) filling a `size` x `size` canvas at `origin`.
func drawIcon(_ ctx: CGContext, origin: CGPoint = .zero, size: CGFloat) {
    let u = size / 1024 // one design unit
    let body = CGRect(x: origin.x + 100 * u, y: origin.y + 100 * u, width: 824 * u, height: 824 * u)
    let shape = squircle(in: body)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Drop shadow under the whole body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 30 * u,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38))
    ctx.addPath(shape)
    ctx.setFillColor(orangeBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [orangeTop.cgColor, orangeBottom.cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])
    // A soft sheen over the upper half.
    let sheen = CGGradient(colorsSpace: space,
                           colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20),
                                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY), options: [])
    ctx.restoreGState()

    // A hairline of light along the top edge, and one of shade along the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setLineWidth(3 * u * 2)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.strokePath()
    ctx.restoreGState()

    // The bolt, with one shadow for its whole silhouette (a transparency layer: filling and stroking
    // with a shadow set would shade the stroke over the fill) and slightly rounded corners.
    let boltShape = boltPath(centeredAt: CGPoint(x: body.midX, y: body.midY + 4 * u), height: 556 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 26 * u,
                  color: CGColor(srgbRed: 0.45, green: 0.18, blue: 0, alpha: 0.38))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(12 * u)
    ctx.addPath(boltShape)
    ctx.drawPath(using: .fillStroke)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    draw(gctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode \(path)") }
    do { try data.write(to: url) } catch { fatalError("cannot write \(path): \(error)") }
}

func iconPNG(size: Int) -> NSBitmapImageRep {
    bitmap(width: size, height: size) { ctx in drawIcon(ctx, size: CGFloat(size)) }
}

/// 1280 x 640, the size GitHub asks for as a repository's social preview.
func socialPreview() -> NSBitmapImageRep {
    bitmap(width: 1280, height: 640) { ctx in
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.setFillColor(CGColor(srgbRed: 18 / 255, green: 20 / 255, blue: 25 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 640))
        // A warm glow behind the icon.
        let glow = CGGradient(colorsSpace: space,
                              colors: [CGColor(srgbRed: 244 / 255, green: 129 / 255, blue: 32 / 255, alpha: 0.34),
                                       CGColor(srgbRed: 244 / 255, green: 129 / 255, blue: 32 / 255, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 290, y: 320), startRadius: 0,
                               endCenter: CGPoint(x: 290, y: 320), endRadius: 430, options: [])
        let iconSize: CGFloat = 420 * 1024 / 824 // the 824-unit body comes out 420 pt wide
        drawIcon(ctx, origin: CGPoint(x: 290 - iconSize / 2, y: 320 - iconSize / 2), size: iconSize)

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: CGPoint) {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
            NSAttributedString(string: s, attributes: attrs).draw(at: point)
        }
        text("Zarp for macOS", size: 80, weight: .bold, color: .white, at: CGPoint(x: 540, y: 340))
        text("One-click Cloudflare WARP", size: 38, weight: .regular,
             color: NSColor(srgbRed: 196 / 255, green: 200 / 255, blue: 208 / 255, alpha: 1), at: CGPoint(x: 544, y: 280))
        text("for networks that block it", size: 38, weight: .regular,
             color: NSColor(srgbRed: 196 / 255, green: 200 / 255, blue: 208 / 255, alpha: 1), at: CGPoint(x: 544, y: 232))
        text("Open source · MIT · Apple Silicon · macOS 14+", size: 26, weight: .medium,
             color: NSColor(srgbRed: 244 / 255, green: 129 / 255, blue: 32 / 255, alpha: 1), at: CGPoint(x: 544, y: 150))
    }
}

// MARK: - Disk image window

/// The content area of the window that opens when the disk image is mounted, in points: the 660 x 400
/// window of scripts/dmg/settings.py minus its 28 pt title bar. A person who has Finder's status bar or
/// path bar switched on (a global setting since macOS 13, which a disk image cannot override) sees about
/// 47 pt less at the bottom, so everything that matters sits in the upper part.
let dmgWindow = CGSize(width: 660, height: 372)
/// Where Finder centres the two icons, measured from the content area's top-left (scripts/dmg/settings.py).
let dmgZarpCenter = CGPoint(x: 170, y: 196)
let dmgApplicationsCenter = CGPoint(x: 490, y: 196)

/// Dark backdrop, a light tile behind each icon, an arrow centred between the tiles, and one line of text.
/// (Less is better here: the README explains the first launch, the window only has to say what to drag.)
///
/// The tiles are light grey on purpose: Finder draws the icon labels itself, in black, whatever the
/// system appearance, so the labels need a light surface to sit on.
func dmgBackground(scale: Int) -> NSBitmapImageRep {
    let w = Int(dmgWindow.width), h = Int(dmgWindow.height)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w * scale, height: h * scale, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale)) // from here on: points, origin bottom-left
    func cgY(_ top: CGFloat) -> CGFloat { CGFloat(h) - top }
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

    let bg = CGGradient(colorsSpace: space, colors: [rgb(31, 33, 42), rgb(14, 15, 19)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(244, 129, 32, 0.16), rgb(244, 129, 32, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: CGFloat(w) / 2, y: cgY(200)), startRadius: 0,
                           endCenter: CGPoint(x: CGFloat(w) / 2, y: cgY(200)), endRadius: 330, options: [])

    // Tiles behind the icons, centred on them (the label then sits in the lower padding), so the arrow can
    // be level with both the icons and the tiles.
    for c in [dmgZarpCenter, dmgApplicationsCenter] {
        let tile = CGRect(x: c.x - 100, y: cgY(c.y + 107), width: 200, height: 214)
        let path = CGPath(roundedRect: tile, cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0, 0, 0, 0.55))
        ctx.addPath(path); ctx.setFillColor(rgb(190, 194, 201)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let fill = CGGradient(colorsSpace: space, colors: [rgb(222, 225, 231), rgb(180, 184, 192)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(rgb(255, 255, 255, 0.22)); ctx.setLineWidth(1); ctx.strokePath()
    }

    // The arrow, orange like the rest of the brand: 80 pt long, centred in the 120 pt gap between the tiles
    // (x 270 to 390) and level with the icon centres, so it touches neither tile.
    let ay = cgY(dmgZarpCenter.y)
    let gapMid = (dmgZarpCenter.x + dmgApplicationsCenter.x) / 2
    let tail = gapMid - 40, tip = gapMid + 40, headBase = tip - 32
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: rgb(244, 129, 32, 0.55))
    ctx.setStrokeColor(rgb(244, 129, 32)); ctx.setFillColor(rgb(244, 129, 32))
    ctx.setLineWidth(10); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: tail, y: ay)); ctx.addLine(to: CGPoint(x: headBase + 2, y: ay)); ctx.strokePath()
    ctx.setLineJoin(.round); ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: headBase, y: ay + 22)); ctx.addLine(to: CGPoint(x: tip - 2, y: ay)); ctx.addLine(to: CGPoint(x: headBase, y: ay - 22)); ctx.closePath()
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // Text.
    let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
    func line(_ s: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let sz = a.size()
        a.draw(at: CGPoint(x: (CGFloat(w) - sz.width) / 2, y: cgY(top) - sz.height))
    }
    line("Drag Zarp to Applications", top: 30, size: 26, weight: .semibold, color: .white)
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: dmgWindow.width, height: dmgWindow.height) // 72 dpi at 1x, 144 dpi at 2x
    return rep
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift appiconset <dir> | png <file> <size> | social <file> | dmg-background <dir>\n".utf8))
    exit(2)
}
switch args[1] {
case "appiconset":
    let dir = args[2]
    var images: [[String: String]] = []
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            writePNG(iconPNG(size: base * scale), to: dir + "/" + name)
            images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: dir + "/Contents.json"))
case "png":
    guard args.count >= 4, let size = Int(args[3]) else { exit(2) }
    writePNG(iconPNG(size: size), to: args[2])
case "social":
    writePNG(socialPreview(), to: args[2])
case "dmg-background":
    writePNG(dmgBackground(scale: 1), to: args[2] + "/background.png")
    writePNG(dmgBackground(scale: 2), to: args[2] + "/background@2x.png")
default:
    exit(2)
}
