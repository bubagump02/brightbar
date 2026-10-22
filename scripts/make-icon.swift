// Writes the app icon as an Icon Composer bundle: a sunset gradient and, on
// top, the menu bar sun half filled like its gauge. make-app.sh compiles it
// with actool, so macOS 26 renders it in Liquid Glass instead of putting a
// legacy icon on a gray plate. Run from the repo root:
//   swift scripts/make-icon.swift Resources/AppIcon.icon

import AppKit

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

/// Full-bleed square; the system masks it to the icon shape.
func background(_ ctx: CGContext) {
    let sky = CGGradient(colorsSpace: p3, colors: [
        CGColor(srgbRed: 0.27, green: 0.16, blue: 0.55, alpha: 1),
        CGColor(srgbRed: 0.93, green: 0.36, blue: 0.40, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.78, blue: 0.30, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: canvas), options: [])
    let glow = CGGradient(colorsSpace: p3, colors: [
        CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 440, options: [])
}

/// As in MenuBarIcon: eight rays, disk filled from the bottom up.
func sun(_ ctx: CGContext) {
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineWidth(58)
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        ctx.move(to: CGPoint(x: center.x + cos(a) * 280, y: center.y + sin(a) * 280))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * 375, y: center.y + sin(a) * 375))
    }
    ctx.strokePath()

    let disk = CGRect(x: center.x - 182, y: center.y - 182, width: 364, height: 364)
    ctx.setLineWidth(54)
    ctx.strokeEllipse(in: disk)
    ctx.clip(to: CGRect(x: 0, y: 0, width: canvas, height: center.y))
    ctx.fillEllipse(in: disk)
}

func png(_ draw: (CGContext) -> Void) -> Data {
    let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let json = """
{
  "fill" : "automatic",
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "sun.png",
          "name" : "sun"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.3
      }
    },
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "background.png",
          "name" : "background"
        }
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icon")
let assets = out.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try png(background).write(to: assets.appendingPathComponent("background.png"))
try png(sun).write(to: assets.appendingPathComponent("sun.png"))
try json.write(to: out.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("wrote \(out.path)")
