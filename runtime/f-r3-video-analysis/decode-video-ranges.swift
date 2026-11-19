import Foundation
import AVFoundation
import VideoToolbox
import AppKit

// Read-only exact-sample decoder: selected full frames use their actual sample PTS, no seek approximation.
let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let root = URL(fileURLWithPath: args[2], isDirectory: true)
let ranges: [(String, Double, Double)] = args.dropFirst(3).map {
    let parts = $0.split(separator: ":"); precondition(parts.count == 3)
    return (String(parts[0]), Double(parts[1])!, Double(parts[2])!)
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for r in ranges { try FileManager.default.createDirectory(at: root.appendingPathComponent(r.0), withIntermediateDirectories: true) }
let tracks = try await asset.loadTracks(withMediaType: .video)
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
output.alwaysCopiesSampleData = false
reader.add(output); precondition(reader.startReading())
var records: [[String: Any]] = [], allTimes: [Double] = []
var invalid = 0, index = 0
while let sample = output.copyNextSampleBuffer() {
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    guard pts.isFinite else { invalid += 1; continue }
    allTimes.append(pts)
    let selected = ranges.filter { pts >= $0.1 && pts <= $0.2 }
    if !selected.isEmpty {
        try autoreleasepool {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { fatalError("Missing decoded image") }
            var image: CGImage?
            precondition(VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr)
            let cg = image!
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let png = bitmap.representation(using: .png, properties: [:])!
            for r in selected {
                let filename = String(format: "frame-%06d-%.6f.png", index, pts)
                try png.write(to: root.appendingPathComponent(r.0).appendingPathComponent(filename))
                records.append(["range": r.0, "index": index, "pts": pts, "file": r.0 + "/" + filename,
                                "width": cg.width, "height": cg.height])
            }
        }
    }
    index += 1
}
precondition(reader.status == .completed)
let report: [String: Any] = ["method": "AVAssetReader BGRA + VTCreateCGImageFromCVPixelBuffer; actual sample PTS; full uncropped frames",
    "finiteSampleCount": allTimes.count, "invalidTimingSamples": invalid, "allFinitePTS": allTimes, "selectedFrames": records]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("exact-frames.json"))
print("Decoded \(allTimes.count) finite samples; wrote \(records.count) exact frames; invalid timing \(invalid)")
