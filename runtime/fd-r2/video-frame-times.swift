import Foundation
import AVFoundation
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let tracks = try await asset.loadTracks(withMediaType: .video)
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
reader.add(output)
reader.startReading()
var times: [Double] = []
var invalidTimingSamples = 0
while let sample = output.copyNextSampleBuffer() {
    let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    if time.isFinite { times.append(time) } else { invalidTimingSamples += 1 }
}
precondition(reader.status == .completed)
let bytes = try JSONSerialization.data(withJSONObject: times.sorted(), options: [.prettyPrinted])
try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Encoded finite samples: \(times.count), invalid-timing samples: \(invalidTimingSamples)")
