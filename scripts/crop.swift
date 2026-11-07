import AppKit
import CoreGraphics
import ImageIO

// Usage: swift scripts/crop.swift in.png out.png x y width height   (pixels, origin top-left)
let a = CommandLine.arguments
guard a.count == 7, let x = Int(a[3]), let y = Int(a[4]), let w = Int(a[5]), let h = Int(a[6]),
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let cropped = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)
else { FileHandle.standardError.write(Data("usage: crop.swift in out x y w h\n".utf8)); exit(64) }
CGImageDestinationAddImage(dest, cropped, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
