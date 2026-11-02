# Icon storage and contract seam

Icons are best-effort presentation data. A `CompanionIconReference` carries the host,
agent/project kind, id and opaque version. Models and sender resolvers compare these
small values rather than image bytes. A complete inline snapshot consumes its data URLs
into the store and retains only references. Quick agents keep the bolt; agent emoji precedes images; the shared circular agent face
and sender resolver retain avatar parity from #210. Project faces remain square.
Missing snapshot icons clear references;
REST catalog refreshes reuse the last complete snapshot's reference map.

`CompanionIconStore` is an actor. It performs filesystem access and ImageIO decoding
outside the main actor. View appearance tasks request images; no view body reads disk.
A disappearing view cancels its waiter. Multiple consumers share a request, and the last
cancellation cancels the fetch. Forgetting a host cancels and fences its requests, clears
its negative entries and decoded images, and deletes its disk scope.

The default disk location is Caches/CompanionIcons, excluded from backups. Host scopes
and filenames are SHA-256 digests with length-delimited key components. Only image bytes
are persisted, using atomic replacement. The 64 MiB cache evicts least-recently-used files
by persisted access time and admits at most 1 MiB per image. Startup prunes oversized
files and enforces the total budget; corrupt or truncated images are removed on access.
Disk failures return no image and cannot change chat or connection state. A matching
version on disk needs no network, including offline. A different version cannot use old
bytes. Removed appearances cannot reappear from a REST refresh or stale view result.

ImageIO accepts a fixed raster format set (PNG, JPEG, GIF, TIFF, BMP, HEIC/HEIF, WebP),
checks complete input and source dimensions (4,194,304 pixels, 16,384 per edge), and
creates orientation-correct thumbnails at 3× display points (maximum 384 pixels per edge).
SVG and anything that cannot decode use avatar fallback; no WebKit or vector renderer is
used. Decoded thumbnails use a 16 MiB/256-entry NSCache. Inline tokens hash bytes.

The fetch seam accepts a key and byte budget and returns status, content type, bytes and
an adapter-normalized served version. Successful remote responses without a version are
refused. Valid bytes are cached under the returned version only. If it differs from the
requested snapshot version, no image is delivered and that requested version is fenced
from timer retries; a later matching snapshot can use the returned bytes without another
download. A 304 without cached bytes cannot create an association.
The adapter must enforce that byte budget while streaming, before returning data. The
store independently rechecks bytes, MIME and decode. Two requests run at once (hard
maximum three), with a 256-entry pending queue. Failed requests, including 404, back off
from 30 seconds to one hour; the 1,024-entry negative cache is bounded. Retries require
fresh visible demand; no timer continuously retries a failing icon.

## Pending desktop contract

The negotiated protocol adapter is intentionally not enabled until the authoritative
contract and fixtures arrive. No capability or snapshot fields have been invented.
Existing desktop inline snapshots continue to work. Required inputs:

- Capability name, version and client opt-in/handshake mechanism.
- Token field, format and scope; reference maps and explicit removal semantics.
- Whether icons are immutable at that token, plus how races between snapshot and GET work.
- Whether ETag/If-None-Match/304 exist, and the behavior of an icon disappearing.
- Encoded byte, decoded pixel and snapshot/catalog budgets; raster fallback for SVG.
- Authoritative fixtures, including missing, changed, removed and oversized icons.

The existing 16 MiB transport cap is unchanged. `maximumResponseBytes` still applies to
both REST responses and WebSocket messages; this work does not assume desktop phase 1
already has a metadata-only snapshot overflow fallback.

## Provisional contract review (not enabled)

The desktop's v0 proposal supplies strong ETags on 200/304, actual served dimensions and
byte counts, complete appearance broadcasts, and a 32 MiB total cache budget. Those
constraints are compatible: the eventual negotiated policy can lower admission to
72 KiB, 256² source pixels and PNG/JPEG/GIF/WebP, while retaining two concurrent fetches
below the server's four-request ceiling. The current legacy inline store keeps its
original 64 MiB/1 MiB policy until authoritative fixtures establish the negotiated path.
Expected MIME, dimensions and bytes must be checked against actual decoded source
properties and response data. No metadata fields, capability or socket query are wired
by this draft. REST refreshes preserve reference maps; new identities remain initials
until an authoritative appearance broadcast. Omission-retrieval routes are also pending.

## WIP icon refs v1 review (adapter off)

Reviewed the proposed `iconRefs` v1 shape after rebasing on main `9d23c7f`.
This is not an approved wire contract. The reference/returned-version seams fit, but
no provisional capability, query, route, or metadata fields are enabled.

The negotiated adapter will need to set the opt-in on every newly constructed socket
request: the actual reconnect loop rereads capabilities and creates a fresh `/ws` URL.
`telemetry:hello` is gated by telemetry enablement and control availability, so it cannot
identify every mobile connection. An explicit `client=mobile` metrics parameter, if agreed,
should be independent of telemetry and authorization.

Negotiated icon associations need three states. A present complete reference map can
remove entries, while an omitted whole reference object is unknown and preserves the
last associations; REST catalog refreshes also preserve them. Legacy empty icon maps
must not clear negotiated associations when refs are omitted by overflow. This differs
from the legacy inline adapter's complete-snapshot clearing rule. Final fixtures must
cover `snapshotTruncated.omitted`, legacy empty maps, null/unmarked absence, and missing
individual kind maps. Dispatcher having no refs is an intentional change from v0 to
confirm; quick avatars keep their bolt.

Admission must verify the exact canonical four-format type, SHA-256 of served bytes
against strong ETag, actual byte count and actual ImageIO dimensions (both sides at most
256), under the 72 KiB budget. Unknown types, SVG, mismatched metadata or undecodable
bytes fail only the icon and fall back to initials. The negotiated cache should use a
32 MiB bound (a global bound is stricter than a per-desktop allowance); final wording
should settle accounting. Two concurrent fetches remain under the proposed ceiling of
four, and decoded memory is already bounded at 16 MiB.

404 and stale-version outcomes need association-lifetime fences until the snapshot
version changes. Generic store failures currently use bounded timed backoff; that is not
yet the proposed version-long 404 rule, and bounded negative-entry eviction must not
silently re-enable it. A returned mismatched ETag is already cached under its returned
version only. A later matching snapshot can use it; it never fulfills the old version.
"Keep what's drawn" means only an association still valid for the current snapshot,
not an old token after explicit replacement/removal. A same-filename external change
cannot appear before a new snapshot publishes the new byte-derived version.

Still needed before enabling: final approval and committed authoritative fixtures;
exact type literals and SHA casing; complete/partial/null/omitted map semantics;
strong ETag/304/404/stale-response fixtures; byte/type/hash/dimension mismatch and
boundary fixtures; final cache accounting and optional metrics-query wording.
