# #569 main logging result — not reproduced

Reviewed DEBUG logging head **6a208e1f**, product base **3d4d01d7**, unchanged product logic. Fresh build passed in224.54s, compiled deinit and policy checks0. Prefix23 ran once in653.51s: **20P / 2 existing strictE / 1 pointer-wheel skip / 0F**. Exact order and every unrelated outcome matched the confirmation. Target passed61.332s. No product fix or regression acceptance is claimed.

| Restore | Window through delivery | Saved entry lowerBound through delivery | Arrival | Marker y |
|---|---|---:|---:|---:|
| Tab return | hidden15, first reading-16 unchanged | 14345.000 unchanged | 168.849ms | 209.667 |
| Reopen | hidden16, first reading-17 unchanged | 14248.333 unchanged | 169.384ms | 209.667 |

**H1 not exercised:** neither observed delivery has a window hidden/first or saved-entry lowerBound shift between its first step and arrival. A real prefix trim occurs at00:15:20.767778, about5.32s AFTER the first arrival: the entry lowerBound drops96.667pt and the bookmark offset follows by96.667pt, preserving its entry/distance and the marker pixels. This supports testing that same trim inside the pinned-delivery interval; it does not prove H1 caused the historical failure.

**H2 not exercised:** both disappear→next-mount gaps contain zero `saved` lines. The saved entry/distance/offset match across each gap.

**Observability limitation:** long NSLog messages are truncated after1024characters. Some trailing pinned/step/attempt/caller fields are lost. The numeric targets are inferred from source plus the recorded frames/distance/arrival metrics; they are not direct readings of the truncated pin field. Leading event/frame/metrics and hidden/first fields during both delivery windows are present. Do not treat this passing observation as ruling out either hypothesis generally.

No repeats. Next proposed step is a deterministic fixture using the existing DEBUG delivery probe: refuse the first delivery once, append a normal tail entry, require an actual prefix/entry-lowerBound shift before releasing delivery, then retain the6pt pixel check. Independent QA must review it before implementation. No product source has been changed.

Exact owned FEA84FD7-DE3F-42D1-BA84-9B9013A527C9 shut down and deleted; system0Booted, ownedProcesses[], swapgrowth0. Host returned to composer. Full result bundle retained at /tmp/ux-569-logging-proof/tickets/c-main-log-r1/tests.xcresult.
