// Draws the app's icon and assembles Roost.icns out of it.
//
//   swift tool/icon.swift tool/Roost.icns
//
// The icon is not a picture from an editor but the same code as the interface:
// the same colours from the palette, the same right angles, not one rounded
// corner inside. The palette changes — the icon is redrawn, rather than a
// graphics source being hunted for.
//
// The result is committed: building the bundle only copies it.

import AppKit
import CoreGraphics
import Foundation

/// The colours are a copy of `Palette`'s dark theme. The duplication is
/// deliberate: the script is not built together with the app, so there is
/// nothing to import.
let backdropTop = CGColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1)
let backdropBottom = CGColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255, alpha: 1)
let mark = CGColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1)

/// Two cursors, in the interface's own alphabet: one striped, one solid — an
/// agent at work beside one that ran into a question.
///
/// The icon has no colour, because the app has none: states are told apart by
/// how densely their mark is filled, and the two bars here are the top two rungs
/// of that ladder. The stripes blur into a lighter grey at 16 px, which is the
/// same thing said quieter — the ladder survives the loss of detail.
///
/// Drawn across the whole canvas, with no shape and no margins of its own.
/// macOS 26 takes rounding and framing upon itself: a squircle of ours would be
/// inscribed inside its tile, and the result would be an icon inside an icon —
/// verified on a mock bundle.
///
/// Everything is in fractions of the side: the image is drawn anew for every
/// size rather than scaled down from 1024 — at 16 px that is the difference
/// between a block and a blob.
func draw(_ ctx: CGContext, size: CGFloat) {
    let u = size / 1024
    let frame = CGRect(x: 0, y: 0, width: size, height: size)

    // A barely noticeable gradient: a flat fill reads as a hole in the dock.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space, colors: [backdropTop, backdropBottom] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: frame.midX, y: frame.maxY),
        end: CGPoint(x: frame.midX, y: frame.minY),
        options: []
    )

    let width = 176 * u, height = 400 * u, gap = 96 * u
    let bottom = frame.midY - height / 2
    ctx.setFillColor(mark)

    // The left bar is striped — the mark of an agent that is working, and the
    // one thing in this interface allowed to move.
    let band = 28 * u
    var y = bottom
    while y < bottom + height {
        ctx.fill(
            CGRect(
                x: frame.midX - gap / 2 - width,
                y: y,
                width: width,
                height: min(band, bottom + height - y)
            )
        )
        y += band * 2
    }

    // The right bar is solid: waiting, the only state filled completely.
    ctx.fill(CGRect(x: frame.midX + gap / 2, y: bottom, width: width, height: height))
}

func render(size: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(ctx, size: CGFloat(size))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "tool/Roost.icns")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Roost-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// The names are fixed by iconutil's format: it looks for exactly these.
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2)
        .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print(output.path)
