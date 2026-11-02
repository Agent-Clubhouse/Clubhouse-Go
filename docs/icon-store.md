# Icon storage and contract seam

Icons are best-effort presentation data. A `CompanionIconReference` carries the host,
agent/project kind, id and opaque version. Models and sender resolvers compare these
small values rather than image bytes. A complete inline snapshot consumes its data URLs
into the store and retains only references. Missing snapshot icons clear references;
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
checks complete input and source dimensions (40 million pixels, 16,384 per edge), and
creates orientation-correct thumbnails at 3× display points (maximum 384 pixels per edge).
SVG and anything that cannot decode use avatar fallback; no WebKit or vector renderer is
used. Decoded thumbnails use a 16 MiB/256-entry NSCache. Inline tokens hash bytes.

The fetch seam accepts a key and byte budget and returns status, content type and bytes.
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
