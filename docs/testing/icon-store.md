# Icon store test plan

The contract-independent seam is `CompanionIconReference` (host, kind, id, opaque version)
and a cancellable fetch closure returning status, content type, and bounded bytes. No new
snapshot fields or capability names are assumed. Inline versions hash the decoded bytes.

Deterministic domain tests use a temporary directory, generated PNGs, fake time and fetches:

- Exact/over byte budgets, corrupt/truncated/non-image input, pixel limits and 3× thumbnails.
- Disk reuse across store instances, offline hits, atomic files and backup exclusion.
- Per-host hashed directories, token invalidation, complete snapshot removal.
- LRU eviction and total-byte bound, including pre-existing files.
- Visible-demand fetches, two concurrent requests, shared requests, waiter cancellation,
  host removal fencing late writes, negative caching and exponential backoff (including 404).
- Lightweight inline catalogs and identities: no base64/data retained after a large snapshot.
- All icons failing leaves chat/history/connection usable and avatars resolve to initials.

Validation: package tests with coverage; coverage ratchet; Debug build-for-testing; Release
simulator build; app, preview, Dispatcher and long-reply suites on a new private simulator.
Never run live E2E, contact a physical phone, or control the host desktop app.

## Validated on main 9441c43 with avatar parity

- `swift test --enable-code-coverage`: 922 tests passed.
- `scripts/coverage.sh --skip-tests --check`: Transport 96.50%, Domain 94.31%, gates passed.
- Debug build-for-testing and Release simulator build passed.
- All 23 requested preview, Dispatcher and long-reply UI tests passed on a private
  iPhone 17 Pro / iOS 26.0 simulator. Eleven app tests passed in that same run.
- The full simulator result was **34 passed, 2 failed**: the avatar rendering and GIF
  tests were interrupted by the existing main-branch queue crash [#218](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6569053862)
  during root-view startup. A separate targeted rerun passed both tests without another
  failure. This is a retry, not a clean all-at-once simulator pass.
- The frozen build-147 transport audit passed five tests, including the real-time grace
  check, omission shapes, core overflow options and fifteen permission-preview cases.
  Extra outer-event/snapshot negative controls passed in a targeted follow-up.

Only the owned simulator and private loopback peers were used; both peers stopped and
that simulator was deleted after validation. The negotiated wire adapter remains off.

## Rebased review on main 9d23c7f

Package coverage tests and the coverage ratchet were rerun after integrating #216.
The previous simulator/build results above remain evidence for the prior base; they
were not rerun for this focused rebase request. No new wire adapter is enabled.

Reviewed `git diff origin/main...HEAD` file by file, using merge base
`9d23c7f61cbe4d67cab00fd3e4e357cf44fc418c`. No existing file or test case is deleted.
All removed lines are intentional replacement of retained image bytes with references,
replacement of synchronous UIKit caching with async bounded loading, or corresponding
fixture/assertion updates. Main's catalog completeness, capability retention, Dispatcher
unknown state, loading navigation, chat deletion rules and foreground/identity tests
remain intact. An earlier two-tree comparison was against an origin/main that advanced
during validation; the final three-dot review is against the requested #216 base.

File review:

- `CompanionLiveService.swift`: icon catalog/store lifecycle and reference parameters only;
  #216 catalog/Dispatcher/capability state is preserved.
- `CompanionAgentFace.swift`, `CompanionMessageRouting.swift`, `CompanionModels.swift`:
  image presence/reference equality replaces byte equality; avatar precedence retained.
- `CompanionIconCatalog.swift`, `CompanionIconStore.swift`: new contract-independent
  inline adapter and bounded disk/decode/fetch implementation.
- `CompanionDesign.swift`: visible avatar tasks replace body decoding and old UIImage cache.
- `CompanionTimelineCards.swift`: routed face passes reference; main's long-output UI retained.
- `AnnexAppTelemetry.swift`, `AnnexTelemetry.swift`, `docs/opentelemetry.md`: additive
  closed-vocabulary icon measurements, keeping main's performance measurements.
- `CompanionAvatarRenderingTests.swift`, `CompanionIconDecoderTests.swift`: actual bounded
  image path and SVG/GIF smoke coverage; existing avatar test retained as async.
- `AppTelemetryTests.swift`: additive icon test; main's performance test preserved.
- `AnnexContractDispatcherTests.swift`, `AnnexContractDomainRobustnessTests.swift`,
  `AnnexContractDomainTests.swift`, `AnnexContractSenderIdentityTests.swift`: reference
  expectations; truncated fixture image headers rejected and valid raster supplied
  in memory for precedence tests. No server fixtures changed.
- `CompanionAgentFaceTests.swift`, `CompanionHomeLayoutTests.swift`,
  `CompanionLiveServiceSyncTests.swift`, `CompanionMessageRoutingTests.swift`: preserve
  cases and change icon arguments/assertions to references.
- `CompanionIconStoreTests.swift`: new bounds, disk, lifecycle, fallback and retention cases.
- `ScriptedAnnexTransport.swift`: optional injected temp icon store only; main's paused
  reads and refresh/failure helpers retained.
- `Build147SnapshotShapeTests.swift`, `Build147TransportAuditTests.swift`,
  `websocket_close_peer.py`: isolated archived-client compatibility harness additions.
- `docs/icon-store.md`, `docs/testing/icon-store.md`, `build147-overflow-options.md`,
  `build147-permission-previews.md`, `build147-snapshot-compatibility.md`: design,
  contract hold, measured compatibility results and validation limits.
