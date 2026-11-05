#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Prepare Medina's dark station tile on a white canvas. Only edge-connected
// background is removed; ivory details enclosed by the tile are untouched.
// Preserve the external shadow as translucent black rather than a white halo.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fatalError("Usage: swift generate-app-icon.swift <source.png> <AppIcon.appiconset>")
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height, image.width >= 1024 else {
    fatalError("The source must be a square PNG at least 1024 pixels wide")
}
let width = image.width, height = image.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
var outside = [Bool](repeating: false, count: width * height)
var queue: [Int] = []
func enqueue(_ index: Int) {
    guard !outside[index] else { return }
    let offset = index * 4
    guard min(pixels[offset], pixels[offset + 1], pixels[offset + 2]) >= 112 else { return }
    outside[index] = true
    queue.append(index)
}
for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
var cursor = 0
while cursor < queue.count {
    let index = queue[cursor]
    cursor += 1
    let x = index % width, y = index / width
    if x > 0 { enqueue(index - 1) }
    if x + 1 < width { enqueue(index + 1) }
    if y > 0 { enqueue(index - width) }
    if y + 1 < height { enqueue(index + width) }
}
for index in queue {
    let offset = index * 4
    let alpha = 255 - min(pixels[offset], pixels[offset + 1], pixels[offset + 2])
    pixels[offset] = 0
    pixels[offset + 1] = 0
    pixels[offset + 2] = 0
    pixels[offset + 3] = alpha
}
let prepared = context.makeImage()!
let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for size in sizes {
    let pixels = size.points * size.scale
    let suffix = size.scale == 2 ? "@2x" : ""
    let filename = "icon_\(size.points)x\(size.points)\(suffix).png"
    let scaled = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                           bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: bitmapInfo)!
    scaled.interpolationQuality = .high
    scaled.draw(prepared, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let outputURL = destination.appendingPathComponent(filename)
    let output = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, scaled.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not write \(filename)") }
    entries.append(["idiom": "mac", "size": "\(size.points)x\(size.points)",
                    "scale": "\(size.scale)x", "filename": filename])
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination.appendingPathComponent("Contents.json"))
print("Generated \(sizes.count) macOS icon assets in \(destination.path)")
