import Foundation
import AVFoundation
import Vision

// The hosted fixture labels every return; the simulator recording supplies committed pixels,
// independently of SwiftUI geometry and the hosted test's presentation-layer assertions.
guard CommandLine.arguments.count == 2 else {
    print("Usage: swift scripts/verify-reading-return-video.swift RECORDING.mp4")
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    print("ERROR: The return recording has no video track")
    exit(1)
}
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
])
reader.add(output)
guard reader.startReading() else { throw reader.error! }
let cached = try NSRegularExpression(pattern: "(iphone|ipad)[- ](12|100)[- ]cached", options: .caseInsensitive)
let marker = try NSRegularExpression(pattern: "marker\\s+(\\d+)", options: .caseInsensitive)
var frame = 0
var labeled: [String: Int] = [:]
var readable: [String: Int] = [:]
var failures: [String] = []
while let sample = output.copyNextSampleBuffer() {
    defer { frame += 1 }
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    let range = NSRange(text.startIndex..., in: text)
    guard let match = cached.firstMatch(in: text, range: range),
          let nameRange = Range(match.range, in: text),
          let countRange = Range(match.range(at: 2), in: text),
          let count = Int(text[countRange]) else { continue }
    let name = String(text[nameRange]).lowercased()
    labeled[name, default: 0] += 1
    let markers = marker.matches(in: text, range: range).compactMap { match -> Int? in
        guard let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
    if !markers.isEmpty { readable[name, default: 0] += 1 }
    if markers.contains(where: { $0 >= count - 1 }) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        failures.append("frame=\(frame) seconds=\(time) case=\(name) markers=\(Set(markers).sorted())")
    }
}
if reader.status == .failed { throw reader.error! }
print("RETURN_VIDEO frames=\(frame) labeled=\(labeled) readable=\(readable)")
for failure in failures { print("WRONG_PRESENTED_FRAME \(failure)") }
guard readable.keys.contains(where: { $0.contains("-12-") }),
      readable.keys.contains(where: { $0.contains("-100-") }) else {
    print("ERROR: The recording must contain readable short and long cached returns")
    exit(1)
}
guard failures.isEmpty else {
    print("ERROR: A committed cached-history frame showed bottom markers")
    exit(1)
}
print("RETURN_VIDEO passed: no committed cached-history frame showed bottom markers")
