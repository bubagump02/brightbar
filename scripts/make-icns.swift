// Builds Resources/AppIcon.icns from the Icon Composer layers (background.png,
// sun.png), with the standard macOS icon shape and shadow. make-app.sh falls
// back to this file when Xcode's actool is missing. Needs only iconutil, which
// ships with macOS. Run from the repo root:
//   swift scripts/make-icns.swift Resources/AppIcon.icon Resources/AppIcon.icns

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icns.swift <AppIcon.icon> <out.icns>\n".utf8))
    exit(2)
}
let assets = URL(fileURLWithPath: args[1]).appendingPathComponent("Assets")
let output = URL(fileURLWithPath: args[2])

func load(_ name: String) -> CGImage {
    let url = assets.appendingPathComponent(name)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("cannot read \(url.path)")
    }
    return img
}
let layers = [load("background.png"), load("sun.png")]

/// Renders the icon at `size` px: 824/1024 rounded square, centered, with a soft shadow.
func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let k = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k,
                  color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    for layer in layers { ctx.draw(layer, in: body) }
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(tool.terminationStatus)
