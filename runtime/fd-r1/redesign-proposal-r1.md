# #582 revised proposal BEFORE code: explicit opening identity request

## Evidence and scope

FD-r1 proves the initialized `ScrollPosition(id:)` does not position this real expanded transcript before its first frame: marker1 is visible before product A corrects to90. No current-approach acceptance is claimed. The lazy semantic seed and once-per-mount CPU fix passed their hosted controls, but the product shape cannot ship on that evidence alone.

I recommend one narrow public-API change before considering a different window contract: issue the cached canonical opening ID through the existing ScrollViewReader proxy in the transcript's **first onAppear**, rather than relying only on the bound ScrollPosition initializer. Keep the eager plain stack, expanded history window and all existing entry identities/coordinates.

Apple documents that the onAppear action completes before the first rendered frame. That is a lifecycle guarantee for the action, **not proof that proxy.scrollTo has completed native layout**; the new recording must establish the latter. ScrollPosition documentation describes visibility adjustment during initial layout, without a first-frame timing guarantee. These sources support this bounded candidate, not a claim it already works:

- [onAppear](https://developer.apple.com/documentation/swiftui/view/onappear(perform:))
- [scrollPosition binding](https://developer.apple.com/documentation/swiftui/view/scrollposition(_:anchor:))
- [scroll target layout, including VStack](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout(isenabled:))

## Proposed product hunk

Add a per-transcript-identity Bool guarding the one opening request. In the existing onAppear, set mounted true, then only on its first occurrence, while paused and a canonical initial ID is still held and not user-positioned, issue `proxy.scrollTo(id, anchor: .top)` synchronously. Mark the opening request consumed regardless of whether an ID exists. No Task, yield, fixed delay, animation, opacity or numeric offset is added. No Store lookup or text slicing occurs there; it reads the cached opening State. Same-state reappear/reload cannot replay the old opening request. Full-target identity and actual unmount still create a fresh seed and request.

Keep product A's loop, geometry checks,20attempt/2s budget, lower-bound retarget, touches, saves and all six-point assertions unchanged. Keep idle-only ID handoff and user ownership guards. The existing canonical aliases and missing/old ID fallback remain.

## Proof and stop

Before any broad suite, the first-frame recording must show marker90 in the FIRST expanded paused frame (not only eventual arrival), including retained-tab, native destination reopen and opposite-state target switches. Log the onAppear request's time and mount ID as observation only. The original deep-ID zero-numeric-arrival test stays unchanged initially; if it still needs one correction, classify from the new pixels rather than relaxing it. Preserve every existing6pt/save/phase/budget check and once-per-mount seed counter. Then the identical main/head scroll and paused-stream measurements and original strict/broad/combined chain still apply.

If the proxy request also lands after first paint, stop and propose a different content-window design. Starting the window at the bookmark would change the current explicit expanded-window/earlier-history contract (`windowFirstID != savedID`); I will not silently implement or weaken that contract. No UIKit introspection or hidden/delayed paint.

## Recording-harness repairs, separate hunks

Before the next recording, fix the offscreen control helper to check a finite nonempty frame intersecting the control strip before querying native hittability, so it can swipe to the existing button. Keep all original scenario/assertion checks. Apply the app's existing preview theme/scheme to the DEBUG fixture so the unaltered pixels have proper contrast; no product-theme change. Both harness deltas require QA static review with the product hunk before building. No code from this proposal has been written.
