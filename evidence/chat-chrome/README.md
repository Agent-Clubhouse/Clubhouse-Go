# Chat chrome evidence — build 210 feedback 356aa756

Source head: `a47f854b255bc06d8c8f9e10879b0a0d81ce5a36`, rebased onto main `3ee127c2` (#295). This evidence commit is separate from the source PR.

All screenshots are from owned simulators and the in-memory preview service. The baseline Dispatcher has Free Agent mode, Full access, a 33% context ring, and the screenshot's single-line report: “Effective context: 258,400 tokens.” Both sides retain the other-agent needs-you banner. The standard-size comparison uses a long reply and the same draft; maximum-text comparisons use the same short Dispatcher conversation and an empty focused composer.

Local runtime: **iOS 26.0**. CI's **26.5** and the phone's **26.7** were unavailable locally.

## Measurements

The visible transcript band is the transcript AX frame intersected with the window, from the greater of transcript/header top to the first composer-region control. The full ScrollView frame extends under bottom bars and is deliberately not reported as usable height. Floating navigation sits within this band; final-line clearance is checked separately.

| iPhone 17 Pro Max (440 × 956 pt) | Before | Final | Change |
| --- | ---: | ---: | ---: |
| Default text, keyboard down | 484.333 | 526.333 | +42.000 |
| Default text, keyboard up | 222.333 | 307.000 | +84.667 |
| Largest accessibility text + keyboard, without preview banner | 38.333 | 87.333 | +49.000 |
| Largest accessibility text + keyboard, with preview banner | 10.000 | 27.333 | +17.333 |
| Slash menu height | 181.667 | 181.667 | unchanged |
| Transcript band above slash menu | 144.000 | 153.667 | +9.667 |

At default text, final text ends 14.667 pt above the floating navigation button, both keyboard down and up. The unchanged assistive entry-width assertion passes at **103 pt** (minimum 100), with Interrupt, attachments, Send and Dismiss Keyboard all reachable.

The first maximum-text implementation regressed without the artificial preview banner (38.333 → 23.333 pt). The final implementation therefore hides only non-safety status/activity/ring rows while an accessibility text size and software keyboard are active. Free Agent and the permission level stay visible; Context remains reachable in Conversation actions. The corrected result is 87.333 pt without the fixture banner. With the fixture banner the screen remains cramped at 27.333 pt, but is better than the 10 pt baseline. These cases retain the other-agent needs-you banner, which can take substantial space at maximum text.

The new maximum-text test requires ≥44 pt without the artificial banner and ≥the measured 10 pt baseline with it, as directed by the orchestrator. It also checks safety labels, controls, and opening Context from Conversation actions. The ring is checked before keyboard presentation. No on-main assertions were relaxed for this comparison.

## Screenshots

- [Before, keyboard down](before-keyboard-down.png) / [after](after-keyboard-down.png)
- [Before, keyboard up](before-keyboard-up.png) / [after](after-keyboard-up.png)
- [Before, slash menu](before-slash.png) / [after](after-slash.png)
- [Before, largest text without preview banner](before-largest-without-preview.png) / [after](after-largest-without-preview.png)
- [Before, largest text with preview banner](before-largest-with-preview.png) / [after](after-largest-text.png)
- [Offline caption and local draft](after-offline.png)
- [iPad keyboard down](ipad-keyboard-down.png) / [up](ipad-keyboard-up.png), [largest text with preview banner](ipad-largest-with-preview.png) / [without](ipad-largest-without-preview.png)

Raw numbers are in [metrics.txt](metrics.txt). The temporary [baseline collector](baseline-max-collector.swift) ran only against main's original four Views and is not in the source branch. The DEBUG-only `--companion-preview-hide-banner` flag removes the artificial label while retaining the preview service; it does not connect to a desktop.

## Choices

- The idle caption is gone. Reconnect, refresh, unsupported-chat and steer/queue explanations still earn their line; the accessibility hint and Command-Return shortcut remain.
- Live context limits and usage are next to the existing Context setting in Agent settings. The ring links there; no composer context picker exists.
- The compact header keeps the permission name and Free Agent warning. Machine/project/model details remain in Conversation details. The expanded permission menu uses an icon to avoid repeating its label.
- Focused and accessibility-size input uses one compact permission/model/effort menu beside the field. Escalation confirmation is hosted in the composer to survive this layout switch. Interrupt and approval are not hidden.
- Send and scroll buttons use system glass styles/control sizes. Scrollable bottom clearance scales with text size so text can be moved clear of floating controls.

## Validation

- Clean Swift package run: 1,166 tests passed on the original base, before #295 was merged. No broader package rerun after the requested rebase/pacing restriction.
- Debug simulator builds and final Release simulator build passed; final jobs used `-jobs 4`, sequentially.
- Composer isolation: all 3 tests passed after the final keyboard/header behavior change, including zero conversation and timeline passes while typing.
- Original focused iPhone batch: 23/24 UI cases passed. The sole failure was a real assistive entry-width regression (91 pt vs 100), fixed by reducing compact-row spacing. Corrective focused batch: 8/8 UI passed, including the unchanged width assertion, offline/reconnect caption, controls, context and Latest.
- Final source-head iPhone geometry/max-text/context-route batch: 3/3 UI and 3/3 isolation passed. An earlier new 44 pt fixture-only assertion was corrected to the explicitly allowed baseline criterion above; no existing assertion changed. Context menu/ring now have distinct AX identifiers because opening a system menu dismisses the keyboard and restores the underlying ring.
- iPad Pro 13-inch (M4): initial focused 8/8 passed; final source-head default/max-text/context-route checks 3/3 passed. Default transcript band: 1,039 pt down, 698.5 pt up; maximum text: 516.5 pt with the preview banner and 576.5 pt without.
- Final deinit policy passed: 28 ARC-only protections, 16 reviewed isolated paths. `git diff --check` passed.
- All created simulators deleted; no owned local heavy jobs remain. No phones, live services, device installs, releases, or host app actions were used.

Only the existing `testReportedContextIsReadOnlyAndAwakePendingChoiceIsLocked` changed its removed-text lookup: it now opens the ring and checks the same report content in Agent settings, retaining awake-lock/reset assertions. Existing keyboard, reading, slash, model/effort, approval and isolation assertions were kept.
