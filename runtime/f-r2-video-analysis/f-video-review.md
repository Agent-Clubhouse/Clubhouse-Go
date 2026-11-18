# #582 F-r2 video packet — independent QA verdict pending

Exact source `5c785b864c4fe706c0b37765672fa9ece0e4283d`, base `85ee757ae3de9d962d0cafab81ad0011314522ab`. A-r6 fresh PASS, compiled deinit gate and 20 policy tests PASS. F-r2 Pro3, FSE1, FAX1 ran once and passed native assertions; FL1 setup ran once but is UNcredited landscape recording (#483). All simulators deleted; all owned process groups closed, system-wide 0 Booted and swap growth0. N and all later phases have not run: video acceptance is an independent prerequisite.

No product inset fix and no main comparator were made or run. Native topInset already covers the banner. Later A scroll intentionally takes inline Show earlier above the viewport. F2 uses a real native status-bar scroll to content top, asserts full native viewport clearance and hittability, then taps. IDs and labels unchanged. DEBUG recording controls are a disclosed2x6 grid consuming part of the viewport.

## Exact encoded samples

`decode-video-ranges.swift` uses AVAssetReader sample buffers, full BGRA decoding and VTCreateCGImageFromCVPixelBuffer. Every PNG is the actual sample with its recorded PTS; no seek/interpolation or assumed frame rate. `exact-frames.json` contains every finite PTS plus selected full-frame paths. Contact sheets are navigation aids only; originals are uncropped. Pro4938, SE547, XXXL604 finite samples; zero invalid timing samples. App wallclock/video start is only bracketed (Pro0.310s), so app-arrived wallclock is supporting evidence, not equated to a video PTS.

| Route | Last previous-state PTS | First paused content PTS | Representative aligned PTS | First entry | Show earlier at first paused paint |
| --- | ---: | ---: | ---: | --- | --- |
| Initial paused open |23.963333 (latest180)|23.998333|24.298333|90|fully below banner|
| Tab return |preceding hidden surface|32.846667|32.995000|90|fully below banner|
| Destination reopen |41.033333 (ready)|41.266667|41.395000|90|fully below banner|
| A/B switch back Maple |54.651667 (Cedar)|54.785000|54.995000|90|fully below banner|
| SE portrait paused open |17.828333 (ready)|18.325000|18.423333|90|fully below banner|
| XXXL portrait paused open |17.028333 (ready)|17.531667|17.633333|canonical90, partially visible|fully below banner|

The XXXL first frame exposes only the first line “Reading” of row90; its number is covered by Latest/composer in this deliberately reduced DEBUG viewport until A aligns. This is explicitly disclosed rather than claiming number90 is pixel-readable at that first sample. It remains the top partially visible row; no earlier or latest transcript flashes. QA must assess that extra-first-frame gate from the actual image. System Apple-Intelligence notification also appears at the top in this recording; it does not cover Show earlier. No repeat or notification manipulation was used.

## Bounded post-paint movement

All saved distances are0, derived from real mounted geometry. Product observations show seed0 followed by A's arrived offset. No paused ID seed/handoff remains.

| Route | Native movement pt | Allowed header+padding+saved distance+6pt | OCR text-glyph movement, supporting only |
| --- | ---: | ---: | ---: |
| Initial |38.333333|44.333333|244.558→205.651 (38.907)|
| Tab |38.333333|44.333333|244.558→205.651 (38.907)|
| Destination |38.333333|44.333333|244.558→205.651 (38.907)|
| Switch Maple |38.333333|44.333333|244.558→205.651 (38.907)|
| SE |38.5|44.5|202→164 (38)|
| XXXL |126.333333|132.333333|wrapped glyph cannot be compared with single-line OCR; full frames + native geometry retained|

Pixel OCR boxes are observations, not AX frame geometry; antialiasing/candidate recognition explains small differences. Canonical row stays at least partially visible throughout each selected exact sequence. The firstMaple switch PTS is54.785000, correcting an earlier rough54.780000 note (no such exact sample exists).

## Real Show earlier expansion and tail

F2 native-top clearance: earlier `(144,204.333,152,14.333)` is fully inside native transcript track `(407,180.333,30,370.667)`; real banner View action `(355,132,61,34.333)`. Label `Show earlier messages`, identifier `companion-show-earlier`. Anchor90 before and after expansion and a normal store tail remains at AX y240.666667 (floating error≈2.5e-11pt), unchanged4pt assertions pass. Boundary becomes entry1; earlier entries can be reached by subsequent intentional native swipes. Canonical90 is not the first row after expansion, as intended.

Exact last pre-expansion samples92.365/92.408333/92.460 and all55 encoded prepend samples97.013333–97.961667 retained. Tail samples104.005–108.900 retained. OCR glyph90 y244.558 throughout the latter ranges; native4pt test is decisive. At108.916667 video begins the test's explicit native swipe to reach older history; that deliberate gesture is not counted as tail drift. Full test activities and app user-scroll/cancellation trace retained for the boundary.

F3 keyboard/draft reload, hidden-return, and missing-session behavior ran unchanged; UI/native checks pass. Short bookmark/latest controls pass. Their eventual state does not replace first-frame proof.

Raw175,023,756-byte Pro video is split byte-for-byte into40MiB parts for GitHub's per-file limit; manifest records original SHA and reassembly command. Extra videos are original bytes. No transcoding. Complete native attachments, outcome/order audits, receipts, full stdout gzip, actualPTS inventories and selected full-frame archives are retained. One interleaved malformed app stdout line has no timestamp: analyzer rejects and records it; never invents a time. Raw stdout remains intact.
