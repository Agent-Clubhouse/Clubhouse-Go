# Typed-value observation boundary

This isolated successor to `b63733a131fb461b4cb5b4e34020e6f84383843e`
corrects only the shared helper's deadline and diagnostic trail. It does not
approve or integrate the inherited per-field wait changes.

The helper uses a monotonic admission deadline before each accessibility read
and before accepting its result. Parking is capped by the remaining budget.
Zero budget admits no read. A synchronous accessibility request cannot be
interrupted: elapsed execution may exceed the admission budget, but a result
returned after that deadline cannot pass. The failure reports elapsed time and
this limitation. The existing 10-second default and explicit 5-second Unicode
budget remain unchanged.

Acceptance and consecutive observation deduplication compare optional UTF-8
bytes, not canonically equivalent Swift strings. The helper sends no input.
A timely exact observation does not prove every earlier insertion or continued
durability after that observation.

## Inert regression controls

Run `python3 scripts/check-typed-value-polling.py`. It extracts the exact helper
and budget from the Swift source and executes them against inert getter and
failure-sink stubs. Controls cover a late matching read, zero budget, timely
success, canonically equivalent byte-distinct wrong observations, and repeated
nil observations followed by timely success. Passing the original source as
the script's optional argument provides the fail-before comparison.

These are Foundation/Swift source-semantic controls, not native accessibility,
XCTest, simulator, SDK type-check, full-build, or hosted execution evidence.

## Per-field changes remain pending

Original run `44776415205`, head
`e334c3cf223f00d0adc3371c72ed60c2e7984054`, is the attribution source.
Rendered first-outcome logs are not a substitute for original later trees and
the complete no-intervening-input activity sequence.

| Inherited wait change | Current evidence and disposition |
| --- | --- |
| Agent Sheets `brave-otter two` | No corresponding original failure/later-value evidence verified; pending timing authority. |
| Agent Sheets `brave-otter-kept` | Separately pending original evidence and timing authority. |
| Compact Composer idle `Keep this draft` | Pending original evidence and timing authority. |
| Compact Composer working `direction` | Ordinary and largest-text variants each pending original evidence and timing authority. |
| Compact Composer pending-grant eight-line `draft` | Separately pending original evidence and timing authority. |
| Dispatcher cold single draft | First rendered failure `Keep this dra`; later complete value/no additional input unverified. |
| Hardware Keyboard second line | No corresponding original failure/later-value evidence verified; pending timing authority. |
| Permission Menu draft | No corresponding original failure/later-value evidence verified; pending timing authority. |
| Preview large-text `Hey` | First rendered failure `H`; later complete value/no additional input unverified. |
| Preview no-tap Wake | No corresponding original failure/later-value evidence verified; pending timing authority. |
| Unicode `requireBytes` callers | First slash waiter timeout retained. Each initial/typed/selection/rotation/reopen observation needs its own authority; following exact-byte result unverified. |
| Wake Focus `presentAndType` | Each no-tap/foreground/landscape presentation pending its own evidence and timing authority; reported `After foregroun` later-value claim unverified. |
| Wake Focus `After foreground rotated` | Separately pending original header/catalog evidence and timing authority. |

Dispatcher chooser `Echo draft` also failed at its early read, but that call
site is **not changed by b637**. It receives no wait authority from this helper
correction. Issue #234's instrumented ten-insertion account is separate from
its older untraced `St` report; the latter remains unclassified. Missing
observations neither prove input loss nor establish eventual publication.

No local native run, shared PR update, or integration is authorized by these
controls. Independent exact-head source review and per-field original evidence
remain separate gates.
