import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 把 IconArt 导出成 iconset / 单张 PNG。图形本身只在 Sources/Sweep/IconArt.swift 里定义。
//
//   swiftc -O -parse-as-library Sources/Sweep/IconArt.swift Scripts/make_icon.swift -o .build/make_icon
//   .build/make_icon .build/AppIcon.iconset && iconutil -c icns .build/AppIcon.iconset -o Sources/Sweep/Resources/AppIcon.icns
//   .build/make_icon /tmp/preview.png 1024           # 单张预览

@main
struct IconGen {
    static let variants: [(px: Int, name: String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let target = args.first else {
            print("usage: make_icon <out.iconset|out.png> [size]")
            exit(2)
        }
        if target.hasSuffix(".png") {
            let px = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
            guard let image = IconArt.render(pixels: px) else { exit(1) }
            write(image, to: URL(fileURLWithPath: target))
            print("wrote \(target) \(px)px")
            return
        }
        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        for item in variants {
            guard let image = IconArt.render(pixels: item.px) else { exit(1) }
            write(image, to: URL(fileURLWithPath: target).appendingPathComponent(item.name))
        }
        print("wrote \(variants.count) images to \(target)")
    }

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
