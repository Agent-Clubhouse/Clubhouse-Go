# Compact composer and adjacent Interrupt

## Source and scope

Baseline: main `b17f9f80`, phone build 218. Parent-triaged Framebriar reports
`73e0e7c1` (2026-11-06 04:42:18Z, Working) and `3c1fef9e`
(2026-11-06 04:46:05Z, Done) show the same session. The later compact composer
was approved: “This one good.” Original image blobs were read into this
worktree's ignored `build/composer-layout-reference/`; no images are committed.

`usesCompactControls` depends on focus or accessibility text size, not agent
status. Losing focus expands model/effort controls for both working and idle
agents. Independently, working status places Interrupt left of the input and
adds a steering/queue caption. Thus status alone does not explain the pictures.
The screenshots do not prove the field's focus state; compact rendering follows
the focus/accessibility branch, rather than Done status itself.

Change only `CompanionConversationComposer.swift` and dedicated tests/docs:

1. Keep the existing compact settings menu at every focus/status/text size.
2. Put warning-palette Interrupt immediately before Send, preserving its
   confirmation binding, capability/connection/pending gates and 44pt target.
3. Remove only the normal steering caption, expressing that outcome in an
   accessibility hint. Retain queue, offline, refreshing and unsupported copy,
   with existing pending behavior. No inferred pending delivery claims.
4. Preserve native editor, selection, focus, Return, slash, attachments,
   approvals, sleep and keyboard dismissal behavior.

After the first allocated run measured the existing Attach target at 36pt,
parent authorized a narrow exception in `CompanionAttachments.swift`: retain
the 36pt icon frame inside a minimum 44×44 label/content shape shared by the
picker and preview button. Cache, upload, picker and attachment state behavior
are unchanged.

## Dedicated cases and serial validation plan

`CompanionCompactComposerUITests` covers:

- Idle Dispatcher: empty and typed draft, keyboard down/up, compact settings
  left of field and same row as Send; permissions/model/effort reachable.
- Working River with attachments and assistive dismissal: empty, image-only and typed
  draft, separate Interrupt and Send, adjacent trailing positions, 44pt targets,
  Interrupt opens confirmation without sending or losing the draft.
- Largest accessibility text: the same working attachment/dismissal row fits
  the window and retains reachable settings, Interrupt and Send.

Before serial allocation: Swift frontend parse of changed Swift files and
`git diff --check` only. No build, simulator, physical-device or live commands.

After allocation, parent owns runtime/visual review: build and run the dedicated
UI class on the narrow phone, then existing `CompanionChatChromeUITests`,
`CompanionKeyboardDismissalUITests`, `CompanionComposerIsolationTests` and
attachment/slash cases. Check native editor identity/focus and draft retention
using existing isolation coverage. Review screenshots with empty/typed working
and idle drafts, largest text, keyboard down/up, attachment previews, pinned
approval, sleep, offline, refresh, pending command and queue-only capabilities.
Queue explanation must stay truthful; existing reconnect/loading/errors must
remain visible. Parent runs project build/test/lint checks in its serial slot
and records actual results; parsing is not runtime evidence.

## Relationship to existing work

Issue #272 concerns framework Unicode caret corruption under programmatic
focus; this correction does not touch that path. Preserve #312's composer
probe when rebasing. Do not cherry-pick held Return PR #310. Header/tabbar
consistency remains parent-owned.

Focused feedback issue: #315 (open issues and #272 checked first).

Parent authorized focused compatibility edits in two existing test methods for
the newly permanent nested settings menus:
`CompanionPreviewSmokeTests/testChatControlsMenusAndPersistentApproval` and
opt-in `CompanionLiveE2ETests/test4ModelAndLevelSwitch`. They expect direct
permission/model/effort chips; they now open Chat controls, then each nested
menu, preserving choice, confirmation and approval assertions. The live case
polls the compact control's accessibility value for the selected model rather
than a chip hidden inside a closed menu. No other methods or shared helpers
changed. The opt-in live test remains unrun; this is navigation compatibility,
not authority to contact a live desktop.

## Validation recorded

Allocated tested SHA: `cc959d41351e3b1a2ec87f396139c4de71145856` (before the
successor target/test corrections). The branch was preserved at docs-only head
`e1243666` during the detached run. One jobs-4 Debug build passed on Xcode
26.0.1; four selected UI cases ran serially on an owned 375pt iPhone SE (3rd
generation), iOS 26.0 / 23A343. Each started exactly once, with no test retries:

- Existing `testChatControlsMenusAndPersistentApproval` passed.
- Idle case failed because the dedicated test used an unsupported fixture flag;
  Dispatcher settings require `--companion-preview-context-window`. This does
  not establish a product settings failure.
- Normal and largest-text working cases failed at the initial empty/unfocused
  Attach width: 36pt, below the required 44pt. The fixed 36pt label predates this
  composer change. Both cases stopped before image-only/typed/confirmation/
  dismissal checks; those outcomes are not yet runtime validated.

The UI batch exited 65, with 1 pass and 3 failures in 79.109 seconds. Its
effective generated xctestrun selected only the four UI methods and set
`ParallelizationEnabled=false`; the CLI also disabled parallel testing and
used no retry flags. An initial invalid `-test-iterations 1` invocation was
rejected before any build/test and its log is retained separately.

Evidence stays under ignored `build/composer-cc959-validation/`: result bundle,
logs, generated/effective configuration, summary, test tree, attempt audit and
attachment manifests. Original PNGs exist for the smoke test; the new row
cases failed before their screenshot calls. Their original screen recordings
are retained. Full, unedited PNG frames extracted from those recordings are
explicitly labeled as video-derived, with local blob mappings; they are not
original XCTest screenshot attachments. No image uploads or blob commits.
Owned simulator was shut down/deleted and build/test processes drained.

The successor fixes the fixture flag and actual Attach label target, captures
screenshots before geometry checks, and checks enabled typed controls/Send/
dismissal for hittability and full unobscured app/keyboard bounds. It invokes
dismissal and checks keyboard/focus exit with text and image draft retained.
Existing empty Send semantics, test timeouts and retry policy remain intact.

Successor validation is source-only: `swiftc -frontend -parse` passed for all
five changed Swift files and `git diff --check` passed. No successor runtime
execution is authorized until allocated. Native editor identity through status
changes remains source-reviewed only. Missing preview errors are UI evidence,
not a transport spy: the reviewed Interrupt action only opens confirmation;
the unchanged parent dialog calls the store command only on explicit confirm.
No physical-device or live commands/tests were run.
