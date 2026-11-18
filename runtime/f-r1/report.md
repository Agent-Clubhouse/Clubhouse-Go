# Bookmark-first F-r1 — STOP before N/H/S/CPU/broad

Exact source `a971c93431ca4f1b4493337a3f6e38aef5fa2591`. QA static PASS preceded all work. A-r5 fresh build PASS230.83s; compiled deinit gate PASS,20policy tests PASS. No simulator in A.

F-r1 ran each of the three recorded UI methods exactly once:0P/3F, no retries. Full video is unaltered48,537,221bytes. All subsequent suites remain held. No product/harness correction or second run has happened after this STOP.

## Classification (QA independently reviewed)

1. F1 `:38`: after initial paused, retained tab and native destination reopen, the fixture's Other-chat action cannot be reached by the horizontal-strip helper. It scrolls through the strip but cannot activate the desired action. A/B isolation and short-tail controls were NOT reached. This is a recording-fixture reachability failure; no A/B acceptance is claimed.
2. F2 `:169`: tapping Show earlier never changes the cursor. Actual pixels show the control under the River-needs-you pinned banner. AX calls it hittable; the tap does not reach the intended action. This is a REAL access hard stop. Source attribution to main is pending; no claim that it is pre-existing yet.
3. F3 `:202`: the new method queries `app.textViews["companion-composer"]`, but this product editor is queried throughout the existing suites through `descendants(matching:.any)`. The visible editor exists in the frame. This is a new harness query defect. Keyboard/draft/reload controls were NOT reached; no acceptance credited.

## Pixel evidence and limits

- The first extracted paused content shows marker90, not an earlier-history prefix, on initial/tab/destination. The canonical row remains the top message. Contacts and full unaltered PNGs are included, alongside actual PTS returned by the decoder. The full finite encoded sample list contains2913 timestamps and2 invalid-timing samples are excluded explicitly. Some AVAssetImageGenerator requests return the preceding sample; frame-times.json records the ACTUAL returned timestamp. Do not infer a fixed FPS or claim every encoded frame is decoded distinctly.
- Initial contact: prior latest chat remains through23.376667s; a new paused marker90 window with visible Show earlier appears by23.395s; by23.445s the control has moved under the banner. Tab-return first extracted frame30.215s shows marker90 and the control; the control is obscured by30.241667s. Destination first extracted frame48.648333s shows marker90/control, obscured by48.686667s. These are video-clock observations, not a fabricated exact stdout clock alignment.
- Stdout independently shows A issuing one38.333pt correction on those mounts, arriving50ms later, canonical firstID90, no ID handoff. Its relative-to-video wallclock start has a334.647ms bracket; do not claim frame-exact event causality from that clock. The matching direction/size and before/after frames support that A pulls the inline header into the pinned region.
- Native logs already report topInset180.333pt with the navigation bar maxY116pt. Thus “the native inset simply omits the banner” is not proven. An inside-content padding change could enlarge A's target and cancel itself. The inset proposal must distinguish the native safe area from a deliberate extra scroll-content margin outside the measured row coordinate space.
- Full first-frame acceptance is NOT achieved: route4 is unexecuted, the earlier-access condition fails and expansion/CPU/broad evidence is absent.

## Cleanup / host return

Private simulator1E35DBEE-80B0-4591-BA9A-ADBEECA99CAF Shutdown and DELETED; receipt system-wide0Booted, owned_processes_after_cleanup[], runtime swapgrowth0. F FIFO exited1. Host returned to go-ci-fixes for #587; it subsequently reported2/2 PASS and exact deletion/system0Booted. No ux-582 heavy ticket queued.

The Orchestrator authorized addressing banner access within #582, with separate main77b attribution, an inset design/static review, and separate harness hunks BEFORE any further build. Original6pt/A bounds and original contract files are unchanged. PR584 stays draft.
