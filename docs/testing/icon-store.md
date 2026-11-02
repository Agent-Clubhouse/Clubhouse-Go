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
