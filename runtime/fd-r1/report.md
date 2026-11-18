# #582 FD-r1: real first-paint counterexample

Source/build `caaac033723231c93b8e70e9d8264ed2003cf015`. This one unchanged F1 invocation is diagnostic only, never acceptance. No assertion retry, product edit or test rewrite followed N-r1.

## Result

The expanded paused opening visibly paints **Reading marker 1**, not its saved **Reading marker 90**, then jumps to 90. The initialized identity is still held at offset zero until product A emits its numeric command. This is a real first-paint failure of the current approach, not just the hosted zero-arrival fixture assumption.

The first distinct encoded frame with the new paused transcript is at **21.111667 s** (`frames-fine/frame-0007-21.117.png`, requested21.116667). It shows marker1/2; marker90 is not visible. Further encoded frames at21.151667 and21.173333 still show marker1. The first sampled encoded marker90 frame is **21.215 s** (`frames-fine/frame-0013-21.217.png`, requested21.216667). Those identities are visible in the unaltered full PNGs. The frame transition interval is about103ms; this recording is variable-rate, so the JSON records actual presentation times rather than claiming a constant frame rate.

The app geometry reports **0 → 8605.333333 pt**. The final public AX observation puts marker90 at y202.333333 in a viewport starting y116 (86.333333pt below that public viewport top); this is a later observation, not first paint. Its exact final frame remains the same on tab return. It does not excuse the initial wrong content.

## Time correlation

- Recording command wall clock1795026467.366164.
- `Recording started` observed1795026467.6975548.
- Test command began1795026467.698962.
- Thus the observed recording-start bracket is331.391ms. The report does not pretend that video time0 has an exact wall-clock alignment inside that bracket. The visible identity transition itself is decisive; app events fall within the corresponding bracket.

| Event | App wall time (epoch seconds) | Offset / target |
|---|---:|---|
| Initial paused body |1795026488.543952| ID90, shown300, window first1, no metrics |
| First frames/geometry |1795026488.622731| offset0, entry90 lower8605.333333, ID90 held |
| Further geometry |1795026488.676229| offset≈0, ID90 held |
| History task |1795026488.706196| offset≈0 |
| Numeric command |1795026488.777436| point8605.333333, ID released |
| Geometry after command |1795026488.794362| offset8605.333333 |

`opening-stdout.txt` and `opening-timeline.json` preserve every emitted body/frame/geometry/task/command/arrival event, including the exact arrival and save. No full hosted N timeline was recorded, which remains an explicit evidence limitation.

## Controls and limits

Fresh/latest: the first recorded chat frame around16.69s already shows tail markers179/180 and the final tool/helper area, with Latest absent. It does not start at the window's first marker163. Its initial geometry changes1427.333333→1601.333333 as layout settles. The system Apple Intelligence banner overlaps the header; the transcript landmarks remain visible. The fixture currently has poor text/background contrast, also visible in the unaltered images.

Retained-tab return: the logged offset again starts0 with ID90 then corrects to8605.333333. The full recording and coarse grid include the repeated top→bookmark transition.

Two-chat switch and destination reopen: **NOT REACHED**. The unchanged UI method failed later, after closed-chat setup, because XCTest could not query the offscreen Reopen button's hittability (`Activation point invalid...`). This is a separate recording-harness defect; no rerun is authorized or claimed to fill the missing cases. All pixel/freshness/6pt assertions remain unchanged.

## Cleanup and disposition

FD script rc1/test65 from that later UI failure; video closed rc0,23643336bytes. Owned1D4231DE-C6F1-41A0-971B-9A9EBF3BC1B0 shut down/deleted, system0Booted, ownedprocesses[], swapgrowth0. All acceptance/broad/performance/coverage phases remain held. Do not rewrite the zero-arrival test as fixture-only. The current design needs a reviewed change.
