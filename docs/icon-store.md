# Icon store

Icons are best-effort presentation data. Models and sender resolvers retain small
host/kind/id/version references, rather than base64 or image bytes. Visible avatar
tasks load images asynchronously; view bodies never read disk. Quick agents keep the
bolt, saved agent profile images precede emoji, agent faces are circular, and project faces square.
The Dispatcher uses its entry in the agent reference map.
See [agent avatar provenance and validation](agent-avatar-identity.md) for the profile-image source contract.

## Snapshot and fetch behavior

When capabilities advertise iconRefs v1, every socket connection includes `iconRefs=1`.
Every connection includes `client=mobile` for metrics, independently of telemetry.
Legacy desktops continue sending inline images, whose byte hashes become local versions.

Negotiated snapshots ignore legacy inline maps. Each present object submap is complete:
missing entries remove associations. Missing, null or malformed whole objects/submaps
are unknown and preserve previous associations, including overflow marked by
`snapshotTruncated.omitted`. Invalid entries in a complete map draw initials and are
not fetched. REST catalogs preserve the last snapshot's associations.

`snapshotTruncated` reports the original frame size and the fields omitted to stay
under the desktop's 8 MiB target. Omitted inline `agentIcons`/`projectIcons` retain
their previous associations too, even when the snapshot sends empty maps.
A later complete map can still remove or replace an image. With negotiated icon
references, only omitted `iconRefs` matters; inline maps are unused.
Settings > Your desktops > Connection details shows a quiet image-omission note
until the next complete update. Canvas-only omissions and oversized `canvas:state`
markers show no notice: Go does not use canvases or fetch their recovery routes.

Authenticated icon reads use the existing pinned transport, with a separate 72 KiB
streaming budget. Admission checks the strong quoted ETag's lowercase SHA-256 against
the body, canonical MIME and actual ImageIO type, exact advertised byte count and
raw source dimensions (at most 256 pixels per side), before applying EXIF orientation.
Allowed remote formats are PNG, JPEG, GIF and WebP. GIF uses its first frame; JPEG
orientation is honored in the thumbnail. SVG, malformed,
oversized and undecodable images fall back without affecting chat or the socket.

Bytes are cached only under their returned version. A mismatched response never
fulfills the requested snapshot version; a later matching snapshot can reuse those
validated bytes. 404 and stale responses fence that current association until its
version changes or it is removed. These fences are separate from the bounded transient
failure cache, so unrelated failures cannot evict them. Late responses after removal
or replacement cannot resurrect an association. A 304 without validated cached bytes
cannot create one. Cache hits need no request, including offline. Same-filename disk
replacement becomes visible after a snapshot publishes the new byte-derived version.

## Resource limits and lifetime

`CompanionIconStore` is an actor that owns filesystem work, decoding and fetch scheduling.
Two requests run at once, with shared in-flight work, cancellation when the last consumer
leaves, and a 256-entry pending queue. Transient failures back off from 30 seconds to one
hour in a bounded 1,024-entry cache; no timer continuously retries an icon.

The disk cache is Caches/CompanionIcons, excluded from backup and safe for iOS to purge.
The 32 MiB bound is total across all desktops. Host folders and length-delimited
kind/id/version filenames are hashed; only image bytes are persisted. Atomic writes
and persisted access times support LRU eviction. Startup prunes oversized/abandoned
files, while corrupt or truncated images are removed on access. Forgetting a desktop
cancels/fences its work and removes its entire scope.

Legacy inline admission retains a 1 MiB per-image limit and a broader raster set,
with complete-source and 4,194,304-pixel checks. Negotiated admission is stricter as
above. ImageIO produces orientation-correct thumbnails at 3× displayed points, capped
at 384 pixels per side. Decoded images use a 16 MiB/256-entry cache, costed by pixel
storage. The immutable CGImage wrapper has reviewed ARC-only teardown; it owns no UI.

Metrics use only closed hit/miss/failure/eviction outcomes, bytes and durations through
existing telemetry gates, never names, IDs, paths, URLs or versions. The existing
16 MiB WebSocket cap and shared default REST/WebSocket maximumResponseBytes behavior
remain unchanged; only icon HTTP reads use the smaller streaming budget.
