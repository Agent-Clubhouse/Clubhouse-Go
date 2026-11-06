# Issue 187: bounded content compatibility

Status: source implementation authorized; execution validation and PDF UI remain pending parent review.

## Provenance and scope

- Go base: `97394e89030e0c079e55106a5d8ee567791b078a`.
- Desktop contract: [PR 2479](https://github.com/Agent-Clubhouse/Clubhouse/pull/2479), merged October 30, 2026 at `56209c3e1e31c8f896fcdb3541e75bc993ebab62`.
- Existing Annex fixtures retain their bytes and `SOURCE.json` pin, `4b3b4f59e67adcbe9df477b5f091ae1d9fb81953`. Current, sleeping and paged chat snapshots already contain `contentAnyPath: true`.
- Cases assembled in `CompanionContentParityTests.swift` are synthetic, except explicitly identified unchanged contract snapshots. No synthetic content response is represented as a desktop recording.

Reuse the current rich-content opt-in, connection check, pinned transport and server authorization. The additive snapshot hint changes absolute-path link eligibility; it grants no commands or local filesystem access. Keep relative path discovery, explicit taps, media references, and the phone's own image-copy exception. Do not add home-path or `file://` discovery, prefetch, provider work, or new permissions.

## Acceptance matrix

| Case | Expected result | Focused source coverage |
| --- | --- | --- |
| Rich capability absent/false/malformed, any-path true | No desktop links or content read | Existing rich gating tests; synthetic host-off store case |
| Any-path absent/false/null/wrong type | Default false; relative candidates and whole-segment roots fallback | Strict decoding and legacy path cases |
| Literal true, including empty roots | Supported absolute paths outside roots become eligible in chip and fetch gates | POSIX and Windows synthetic cases |
| New snapshot true to false/absent, or false to true | Replace policy; never OR it with previous state | Store reload and obsolete-load cases |
| Different targets/hosts | No shared policy | Synthetic store cases |
| NUL, empty, over 1024 UTF-16 units, UNC/device/network paths | Refused before content route read; no phone path lookup | Candidate and direct-service cases |
| Relative path, including `../` | Desktop resolves against agent base and makes final decision | Existing discovery retained |
| Missing, folder, FIFO/device, unreadable or revoked access | Bounded desktop refusal; chip eligibility is only a hint | Existing rejection mapping; corrected copy |
| PDF, small base64 response | Decode `pdf` and bounded bytes; never render as SVG/text while PDF UI is deferred | Synthetic response case |
| PDF metadata only, `tooLarge: true` | Preserve metadata without requiring MIME or bytes | Synthetic response case |
| Unknown string kind | Inert `other`, named generic fallback; remove MIME/text/bytes | Synthetic hostile payload case |
| Existing known `other` | Preserve its previous response semantics deliberately | Synthetic regression case |
| Missing/non-string kind or name, invalid base64 | Remain malformed | Existing and synthetic response cases |
| Encoded over 12 MiB, decoded over 8 MiB | Preserve existing rejection boundaries, including for unknown kind | Existing and synthetic boundary cases |
| Current/sleeping snapshots | Decode each snapshot's reported policy, independent of command capabilities | Unchanged contract fixture assertions |
| Cold archive and later archive pages | Own policy, default false on omission; no inheritance from live roots/any-path | Synthetic archive cases |
| Archive page fails | Preserve previous page, policy and retry cursor | Synthetic archive failure case |
| Archive preview and live preview coexist | Archive policy parameter never overwrites live projection, session or store policy | Synthetic store/service isolation cases |

The merged server uses the current `richChatContent` setting on live and archived chat responses. `contentRoots` remains an older-client hint. The server still checks regular files, symlinks, opt-in and authorization after IO. Mobile never probes files to reproduce those decisions.

## Caps and deferred PDF acceptance

The merged desktop sniffs `%PDF-` at offset zero before text, uses `application/pdf`, and caps local PDF preview bytes at 16 MiB. Annex still caps binary at 8 MiB, omits oversized base64 and returns `tooLarge`. Go's existing 12 MiB encoded and 8 MiB decoded limits remain unchanged. Boundary payloads in tests are built in memory rather than committed as large files.

This patch only adds PDF response compatibility. It does **not** complete issue 187: PDFKit or Share/Open In, concrete temporary-file ownership, cleanup on cancellation/replacement/dismissal, and a usable failure fallback require the parent's separate review. Until then a PDF must follow the generic unsupported-format path, never the broad SVG/text branches.

## Change and validation sequence

1. Commit this plan and focused test changes first. They describe APIs introduced by the second commit and are intentionally not claimed passing in isolation.
2. Extend `CompanionContentRoots` with strict default-false `anyPath`; decode it with each snapshot. Carry it separately through archive page/transcript and pass archive context to the existing preview/store gate. Preserve generation checks, current host gates and server authorization. Normalize unknown kinds after the existing validation and correct roots-only copy.
3. Review diffs and parse touched Swift sources only. No builds, typechecks, tests, simulator/device/live/provider runs or fixture refreshes are authorized in this task. Parsing cannot establish type correctness or runtime behavior. In particular, package tests exclude `Views`.
4. Parent reviews source and the deferred PDF ownership plan. Execution validation requires a later serial Dispatcher allocation; full issue acceptance remains with the parent.
