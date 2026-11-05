Test plan — report 356aa756 / build 210

Baseline/after: same owned iPhone 17 Pro Max, iOS 26.0, preview Dispatcher with Full access, Free Agent, live context report and long reply. Capture screenshot attachments plus transcript visible height from transcript AX frame intersected with header/composer bounds. Record keyboard down and software keyboard up using the same draft. Local runtime differs from CI 26.5 and phone 26.7.

Regression cases:
- Input editing remains isolated: zero conversation/timeline passes in CompanionComposerIsolationTests.
- Keyboard: short/long/empty Dispatcher dismissal, streaming draft preservation, assistive dismiss, accessibility text sizes.
- Reading: history prepend, native top, previous/next/latest, keyboard layout, streaming.
- Slash: insertion, hardware keys, outside dismissal; menu available height and transcript readable band must not regress.
- Controls: permission escalation still confirms, provider model/effort menu behavior remains, Interrupt and approval actions remain pinned.
- Context: ring opens existing Agent settings at context, report read-only next to next-start picker, pending choices and locks unchanged.
- iPad: narrow focused keyboard/reading/slash/context checks and layout capture.
- Existing terminal/no-chat/asleep/offline fixtures preserve their affordances.

Validation: clean swift test; Debug and Release simulator build; scripts/check-isolated-deinits.py on Debug binary; focused hosted unit and preview UI tests. Evidence stays on evidence branch/PR, never main.

Directed maximum-text follow-up: compare the same largest accessibility category with keyboard up against original main Views, both with and without the artificial preview banner. Preserve safety labels; if production-like space regresses, hide non-safety header rows/ring only while the accessibility keyboard is shown, and verify Context remains reachable through Conversation actions. Recheck native input isolation. The fixture-only baseline collector is evidence-only; the permanent tests keep safety and routing assertions.
