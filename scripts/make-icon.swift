#!/usr/bin/env swift
// Draws Zarp's app icon (and the GitHub social-preview image) from vector geometry, so the artwork
// is reproducible from this repository and sharp at every size instead of being a downscaled bitmap.
//
//   swift scripts/make-icon.swift appiconset App/Sources/Zarp/Assets.xcassets/AppIcon.appiconset
//   swift scripts/make-icon.swift png docs/images/icon.png 512
//   swift scripts/make-icon.swift social docs/images/social-preview.png
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

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift appiconset <dir> | png <file> <size> | social <file>\n".utf8))
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
default:
    exit(2)
}
