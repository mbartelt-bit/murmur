// Render the simple vector mark in assets/icon.svg into native icon sizes.
// Run from mobile/: swift scripts/icons.swift
import AppKit
func render(_ size: Int, _ destination: String) {
    let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.setFillColor(NSColor(srgbRed: 49/255, green: 93/255, blue: 70/255, alpha: 1).cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    cg.setStrokeColor(NSColor(srgbRed: 245/255, green: 244/255, blue: 239/255, alpha: 1).cgColor)
    cg.setLineWidth(64); cg.setLineCap(.round)
    for (x, height) in [(256,96), (384,320), (512,448), (640,320), (768,96)] {
        cg.move(to: CGPoint(x: x, y: 512 - height/2)); cg.addLine(to: CGPoint(x: x, y: 512 + height/2))
    }
    cg.strokePath()
    let bitmap = NSBitmapImageRep(cgImage: cg.makeImage()!)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
}
render(1024, "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png")
for (density, size) in [("mdpi",48),("hdpi",72),("xhdpi",96),("xxhdpi",144),("xxxhdpi",192)] {
    for name in ["ic_launcher", "ic_launcher_round", "ic_launcher_foreground"] {
        render(size, "android/app/src/main/res/mipmap-\(density)/\(name).png")
    }
}
