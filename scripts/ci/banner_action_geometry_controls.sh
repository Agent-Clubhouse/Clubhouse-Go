#!/bin/bash
# Exercises the exact BannerActionGeometry text from CompanionConnectionRetryLatchTests.swift on synthetic
# CoreGraphics scenes. Host-only and inert: no simulator, app, UIKit or Vision. The label rectangle is supplied
# here; the hosted test obtains it by recognizing "Retry" in the actual render.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/Annex/AnnexTests/CompanionConnectionRetryLatchTests.swift"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
{ echo "import CoreGraphics"; sed -n '/^\/\/ BEGIN BannerActionGeometry/,/^\/\/ END BannerActionGeometry/p' "$source_file"; } > "$work/geometry.swift"
grep -q 'enum BannerActionGeometry' "$work/geometry.swift"
cat > "$work/main.swift" <<'SWIFT'
import CoreGraphics
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

let scale: CGFloat = 3
let canvas = CGSize(width: 400, height: 300)
let pink = CGColor(srgbRed: 0.93, green: 0.82, blue: 0.89, alpha: 1)
let blue = CGColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1)
let ink = CGColor(srgbRed: 0.16, green: 0.09, blue: 0.22, alpha: 1)

/// One layout drawn twice: `control` only in the shown render, `extra` only in the shown render too.
func renders(card: CGRect, control: ((CGContext) -> Void)?, extra: ((CGContext) -> Void)? = nil) -> (CGImage, CGImage) {
    func draw(_ shown: Bool) -> CGImage {
        let context = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Flip to top-left point coordinates, like UIKit.
        context.translateBy(x: 0, y: canvas.height * scale); context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.95, blue: 0.98, alpha: 1)); context.fill(CGRect(origin: .zero, size: canvas))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: card, cornerWidth: 20, cornerHeight: 20, transform: nil)); context.fillPath()
        context.setFillColor(ink); context.fill(CGRect(x: card.minX + 40, y: card.midY - 7, width: 120, height: 14)) // title
        if shown { control?(context); extra?(context) }
        return context.makeImage()!
    }
    return (draw(true), draw(false))
}
func capsule(_ rect: CGRect, _ color: CGColor, label: CGRect) -> (CGContext) -> Void {
    { context in
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)); context.fillPath()
        context.setFillColor(ink); context.fill(label)
    }
}
func patch(_ rects: [CGRect], _ color: CGColor) -> (CGContext) -> Void {
    { context in context.setFillColor(color); rects.forEach { context.fill($0) } }
}
func measure(_ images: (CGImage, CGImage), hit: CGRect, card: CGRect, label: CGRect, defaultSize: Bool = true)
    -> (metrics: BannerActionGeometry.Metrics?, failures: [String]) {
    let painted = BannerActionGeometry.painted(shown: images.0, hidden: images.1, scale: scale, within: hit)
    let metrics = painted.map { BannerActionGeometry.Metrics(visible: $0.bounds, hit: hit, card: card, label: label,
                                                             labelEnclosure: $0.enclosure(of: label), defaultSize: defaultSize) }
    return (metrics, BannerActionGeometry.failures(metrics))
}

// Candidate shape: a 56×32 pill inside a 56×44 target in a 44pt card.
let card = CGRect(x: 16, y: 20, width: 368, height: 44)
let hit = CGRect(x: 316, y: 20, width: 56, height: 44)
let pill = CGRect(x: 316, y: 26, width: 56, height: 32)
let label = CGRect(x: 330, y: 35, width: 28, height: 14)
let good = measure(renders(card: card, control: capsule(pill, pink, label: label)), hit: hit, card: card, label: label)
check(good.failures.isEmpty, "A correct pill passes: \(good.failures)")
check(good.metrics.map { abs($0.visible.height - 32) <= 1 && abs($0.visible.width - 56) <= 1 } == true, "A visible bounds track the painted pill: \(String(describing: good.metrics))")

// B. Same geometry in another color: identical outcome and bounds.
let recolored = measure(renders(card: card, control: capsule(pill, blue, label: label)), hit: hit, card: card, label: label)
check(recolored.failures.isEmpty && recolored.metrics == good.metrics, "B color alone cannot change the result")

// C. Oversized actual control, like the bordered baseline: a 68×56 capsule filling its target in a 58pt card.
let bigCard = CGRect(x: 16, y: 20, width: 368, height: 58)
let bigHit = CGRect(x: 304, y: 21, width: 68, height: 56)
let bigLabel = CGRect(x: 324, y: 42, width: 28, height: 14)
let oversized = measure(renders(card: bigCard, control: capsule(bigHit, pink, label: bigLabel)), hit: bigHit, card: bigCard, label: bigLabel)
check(!oversized.failures.isEmpty, "C the oversized control fails")
for expected in ["above 36", "for a 14", "round", "whole hit target", "card top", "card bottom"] {
    check(oversized.failures.contains { $0.contains(expected) }, "C names '\(expected)': \(oversized.failures)")
}
let oversizedBlue = measure(renders(card: bigCard, control: capsule(bigHit, blue, label: bigLabel)), hit: bigHit, card: bigCard, label: bigLabel)
check(oversizedBlue.failures == oversized.failures, "C fails the same way in another color")

// D. An unrelated 64×28 patch of the candidate color elsewhere cannot rescue the oversized control or move a good one.
let unrelated = patch([CGRect(x: 40, y: 200, width: 64, height: 28)], pink)
let rescued = measure(renders(card: bigCard, control: capsule(bigHit, pink, label: bigLabel), extra: unrelated), hit: bigHit, card: bigCard, label: bigLabel)
check(rescued.failures == oversized.failures, "D an unrelated patch is ignored with the oversized control")
let undisturbed = measure(renders(card: card, control: capsule(pill, pink, label: label), extra: unrelated), hit: hit, card: card, label: label)
check(undisturbed.metrics == good.metrics, "D an unrelated patch does not change a good control")

// E. Nothing drawn inside the target, only disconnected patches elsewhere: no control.
let absent = measure(renders(card: card, control: nil, extra: patch([CGRect(x: 40, y: 200, width: 16, height: 10), CGRect(x: 80, y: 220, width: 16, height: 10)], pink)),
                     hit: hit, card: card, label: label)
check(absent.metrics == nil && absent.failures.first?.contains("drew nothing") == true, "E disconnected patches are not a control")

// F. A changed patch 2pt below the target, not touching it, is excluded.
let nearby = measure(renders(card: card, control: capsule(pill, pink, label: label), extra: patch([CGRect(x: 316, y: 66, width: 56, height: 10)], pink)),
                     hit: hit, card: card, label: label)
check(nearby.metrics == good.metrics, "F a disconnected neighbor is excluded")

// G. A label outside the painted control fails.
let misplaced = measure(renders(card: card, control: capsule(pill, pink, label: label)), hit: hit, card: card, label: CGRect(x: 200, y: 35, width: 28, height: 14))
check(misplaced.failures.contains { $0.contains("outside the painted control") }, "G the label must lie inside the control")

// H. Accessibility size: a tall pill inset 4pt inside a taller target passes text-relative rules; flush to the card fails.
let axCard = CGRect(x: 16, y: 20, width: 368, height: 120)
let axHit = CGRect(x: 250, y: 80, width: 110, height: 60)
let axPill = CGRect(x: 250, y: 84, width: 110, height: 52)
let axLabel = CGRect(x: 270, y: 94, width: 70, height: 32)
let accessible = measure(renders(card: axCard, control: capsule(axPill, pink, label: axLabel)), hit: axHit, card: axCard, label: axLabel, defaultSize: false)
check(accessible.failures.isEmpty, "H accessibility pill passes without the default ceiling: \(accessible.failures)")
let flushHit = CGRect(x: 250, y: 84, width: 110, height: 56)
let flush = measure(renders(card: axCard, control: capsule(flushHit, pink, label: axLabel)), hit: flushHit, card: axCard, label: axLabel, defaultSize: false)
check(flush.failures.contains { $0.contains("card bottom") } && flush.failures.contains { $0.contains("whole hit target") }, "H a flush accessibility pill fails: \(flush.failures)")

// I. The actual Retry wholly to the right of the card, vertically aligned with it, fails.
let narrowCard = CGRect(x: 16, y: 20, width: 280, height: 44)
let outside = measure(renders(card: narrowCard, control: capsule(pill, pink, label: label)), hit: hit, card: narrowCard, label: label)
check(outside.failures.contains { $0.contains("outside the card") }, "I a control beside the card fails: \(outside.failures)")
check(outside.failures.count == 1, "I fails only for card containment: \(outside.failures)")

// J. Changed pixels only in the label, with no pill around it, fail; so does the same in another color.
for color in [ink, CGColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1)] {
    let bare = measure(renders(card: card, control: patch([label], color)), hit: hit, card: card, label: label)
    check(bare.failures.contains { $0.contains("no painted surface encloses the label") }, "J bare label text fails: \(bare.failures)")
}
check((good.metrics?.labelEnclosure ?? 0) >= 0.99, "J a real pill encloses its label: \(String(describing: good.metrics?.labelEnclosure))")

// K. Non-finite or empty geometry is rejected before any comparison.
for broken in [CGRect.null, CGRect(x: 16, y: 20, width: CGFloat.infinity, height: 44), CGRect(x: 16, y: 20, width: 0, height: 44)] {
    let metrics = good.metrics.map { var m = $0; m.card = broken; return m }
    check(BannerActionGeometry.failures(metrics).first?.contains("not a finite, nonempty rectangle") == true, "K card \(broken) is rejected")
}
check(BannerActionGeometry.painted(shown: renders(card: card, control: nil).0, hidden: renders(card: card, control: nil).1, scale: scale,
                                   within: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == nil, "K a non-finite target measures nothing")

print(failures == 0 ? "BANNER_ACTION_GEOMETRY_CONTROLS PASS" : "BANNER_ACTION_GEOMETRY_CONTROLS FAIL \(failures)")
exit(failures == 0 ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 "$work/geometry.swift" "$work/main.swift" -o "$work/controls"
"$work/controls"
