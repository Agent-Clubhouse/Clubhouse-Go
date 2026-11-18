import Foundation
import Vision
import AppKit

// Read-only evidence analysis. Bounding boxes are OCR observations, not authoritative AX/frame geometry.
var results: [[String: Any]] = []
for file in CommandLine.arguments.dropFirst() {
    let image = NSImage(contentsOfFile: file)!
    var rect = CGRect(origin: .zero, size: image.size)
    let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cg).perform([request])
    let rows: [[String: Any]] = (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return ["text": candidate.string, "confidence": candidate.confidence,
                "x": box.minX * Double(cg.width), "y": (1-box.maxY) * Double(cg.height),
                "width": box.width * Double(cg.width), "height": box.height * Double(cg.height)]
    }
    results.append(["file": file, "width": cg.width, "height": cg.height, "rows": rows])
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
