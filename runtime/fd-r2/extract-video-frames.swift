import Foundation
import AVFoundation
import AppKit

// Read-only native decoder. Writes unaltered frames requested by explicit relative-video times.
// A screenshot/AX observation is never substituted for the first rendered frame.
let arguments = CommandLine.arguments
precondition(arguments.count >= 4, "video outputDirectory seconds [seconds...]")
let video = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let asset = AVURLAsset(url: video)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
var report: [[String: Any]] = []
for (index, raw) in arguments.dropFirst(3).enumerated() {
    guard let seconds = Double(raw), seconds >= 0 else { fatalError("Invalid explicit frame time") }
    var actual = CMTime.zero
    let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: &actual)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    let name = String(format: "frame-%04d-%.3f.png", index, seconds)
    try png.write(to: output.appendingPathComponent(name))
    report.append(["requestedSeconds": seconds, "actualSeconds": CMTimeGetSeconds(actual), "file": name,
                   "width": image.width, "height": image.height])
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appendingPathComponent("frame-times.json"))
print(String(decoding: data, as: UTF8.self))
