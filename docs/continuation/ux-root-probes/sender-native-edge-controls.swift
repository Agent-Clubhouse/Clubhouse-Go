import Foundation
import CoreGraphics
        func previousFrameAgreement(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let pairs: [(CGFloat, CGFloat)] = [(lhs.origin.x, rhs.origin.x), (lhs.origin.y, rhs.origin.y),
                                               (lhs.width, rhs.width), (lhs.height, rhs.height)]
            return pairs.allSatisfy { pair in
                pair.0.isFinite && pair.1.isFinite
                    && abs(pair.0 - pair.1) <= max(pair.0.ulp, pair.1.ulp) * 4
            }
        }
        func sameNativeFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let components = [lhs.origin.x, lhs.origin.y, lhs.width, lhs.height,
                              rhs.origin.x, rhs.origin.y, rhs.width, rhs.height]
            guard components.allSatisfy({ $0.isFinite }),
                  lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return false }
            let pairs: [(CGFloat, CGFloat)] = [(lhs.minX, rhs.minX), (lhs.minY, rhs.minY),
                                               (lhs.maxX, rhs.maxX), (lhs.maxY, rhs.maxY)]
            return pairs.allSatisfy { pair in
                pair.0.isFinite && pair.1.isFinite
                    && abs(pair.0 - pair.1) <= max(pair.0.ulp, pair.1.ulp) * 4
            }
        }
var cases: [[String: Any]] = []
func check(_ name: String, _ actual: Bool, _ expected: Bool) {
    precondition(actual == expected, name)
    cases.append(["case": name, "actual": actual, "expected": expected])
}
let a = CGRect(x:54, y:245.99999999999983, width:263, height:30.333333333333258)
let b = CGRect(x:54, y:245.99999999999986, width:263, height:30.33333333333323)
let priorLive = CGRect(x:54, y:245.9999999999998, width:263, height:30.33333333333326)
let clear = CGRect(x:0,y:143.33333333333334,width:402,height:456.66666666666663)
check("actual-new-pair-fails-previous", previousFrameAgreement(a,b), false)
check("actual-new-pair-edge-agreement", sameNativeFrame(a,b), true)
check("actual-new-pair-symmetric", sameNativeFrame(b,a), true)
check("actual-old-pair-still-agrees", sameNativeFrame(a,priorLive), true)
check("actual-both-unmodified-fit", clear.contains(a) && clear.contains(b), true)
check("actual-bottom-edges-identical", a.maxY == b.maxY, true)
check("unchanged", sameNativeFrame(a,a), true)
func stepping(_ v: CGFloat, _ n: Int) -> CGFloat { var x=v; for _ in 0..<n {x=x.nextUp}; return x }
func withEdge(_ edge: Int, steps: Int) -> CGRect {
    let e = [a.minX,a.minY,a.maxX,a.maxY]
    var f=e;f[edge]=stepping(e[edge],steps)
    return CGRect(x:f[0],y:f[1],width:f[2]-f[0],height:f[3]-f[1])
}
for edge in 0..<4 {
    check("edge-\(edge)-4ULP", sameNativeFrame(a,withEdge(edge,steps:4)), true)
    check("edge-\(edge)-5ULP", sameNativeFrame(a,withEdge(edge,steps:5)), false)
}
for displacement: CGFloat in [0.001,1.0/3.0] {
    check("translate-x-\(displacement)", sameNativeFrame(a,a.offsetBy(dx:displacement,dy:0)), false)
    check("translate-y-\(displacement)", sameNativeFrame(a,a.offsetBy(dx:0,dy:displacement)), false)
    check("widen-\(displacement)", sameNativeFrame(a,CGRect(x:a.minX,y:a.minY,width:a.width+displacement,height:a.height)),false)
    check("height-\(displacement)", sameNativeFrame(a,CGRect(x:a.minX,y:a.minY,width:a.width,height:a.height+displacement)),false)
}
for field in 0..<4 {
    for value: CGFloat in [.nan,.infinity,-.infinity] {
        var c:[CGFloat]=[a.origin.x,a.origin.y,a.width,a.height];c[field]=value
        let f=CGRect(x:c[0],y:c[1],width:c[2],height:c[3])
        check("nonfinite-\(field)-\(value)",sameNativeFrame(a,f),false)
        check("nonfinite-symmetric-\(field)-\(value)",sameNativeFrame(f,a),false)
    }
}
for field in 2..<4 {
    for value: CGFloat in [0,-1] {
        var c:[CGFloat]=[a.origin.x,a.origin.y,a.width,a.height];c[field]=value
        check("nonpositive-\(field)-\(value)",sameNativeFrame(a,CGRect(x:c[0],y:c[1],width:c[2],height:c[3])),false)
    }
}
let huge=CGRect(x:CGFloat.greatestFiniteMagnitude,y:10,width:CGFloat.greatestFiniteMagnitude,height:20)
check("computed-edge-overflow",sameNativeFrame(huge,huge),false)
let touching = CGRect(x:10,y:clear.minY,width:100,height:30)
let outside = CGRect(x:10,y:clear.minY.nextDown,width:100,height:30)
check("boundary-representation-may-agree",sameNativeFrame(touching,outside),true)
check("boundary-both-strict-containment-refuses",sameNativeFrame(touching,outside) && clear.contains(touching) && clear.contains(outside),false)
let result:[String:Any] = ["count":cases.count,"pass":true,"cases":cases,"limit":"Extracted actual Foundation-only comparator; no UIKit/XCUIElement, worker, FIFO or native simulator execution. No runtime/hittability/currentness credit."]
let bytes=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:bytes,as:UTF8.self))
