# Issue 187: bounded content compatibility

Status: source implementation authorized, including the in-memory PDF preview below; execution validation remains pending parent review.

## Provenance and scope

- Go base: `97394e89030e0c079e55106a5d8ee567791b078a`.
- Desktop contract: [PR 2479](https://github.com/Agent-Clubhouse/Clubhouse/pull/2479), merged October 30, 2026 at `56209c3e1e31c8f896fcdb3541e75bc993ebab62`.
- Existing Annex fixtures retain their bytes and `SOURCE.json` pin, `4b3b4f59e67adcbe9df477b5f091ae1d9fb81953`. Current, sleeping and paged chat snapshots already contain `contentAnyPath: true`.
- Cases assembled in `CompanionContentParityTests.swift` are synthetic, except explicitly identified unchanged contract snapshots. No synthetic content response is represented as a desktop recording.

Reuse the current rich-content opt-in, connection check, pinned transport and server authorization. The additive snapshot hint changes absolute-path link eligibility; it grants no commands or local filesystem access. Keep relative path discovery, explicit taps, media references, and the phone's own image-copy exception. The November 7 file-view clarification also admits desktop-home references as described below. Do not add `file://` discovery, prefetch, provider work, or new permissions.

### Direct scratch previews

The user requested direct in-app viewing of agent scratch and out-of-root files, without repeated project-path prompts or an external-open fallback. Ordinary absolute scratch paths already use `contentAnyPath: true`. Home-relative `~/...` and `~\...` references now use the same negotiated eligibility, while the original raw path is forwarded unchanged. The desktop owner verified `cleanCandidate` at desktop main `0e882979` expands these forms using desktop `os.homedir`; relative paths use the desktop agent cwd. Go does not expand the phone's home or add a confirmation protocol.

Discovery, the Store eligibility gate, and direct-service lexical checks accept these home forms consistently. Missing/false any-path still withholds home chips and Store reads. Each archived conversation keeps its own snapshot hint; this is not archive-entry extraction or containment permission. NUL/length/type/byte limits, peer/target authorization, the rich-content opt-in, and UNC/device/network refusals remain. Generic URI refusal remains pending a separate corrected desktop local-file-URL contract; `~other/...` and bare `~` are not added.

New synthetic tests cover home discovery, negotiation and archive isolation, raw service forwarding, and a single query-encoding round trip for spaces, Unicode, `#`, `%20`, and backslashes. These tests are proposed until run on the successor. Real in-app scratch text/image/PDF viewing remains delivery validation, not proof supplied by URL construction or the separate frozen PDF hosted run.

## Acceptance matrix

| Case | Expected result | Focused source coverage |
| --- | --- | --- |
| Rich capability absent/false/malformed, any-path true | No desktop links or content read | Existing rich gating tests; synthetic host-off store case |
| Any-path absent/false/null/wrong type | Default false; relative candidates and whole-segment roots fallback | Strict decoding and legacy path cases |
| Literal true, including empty roots | Supported absolute paths outside roots become eligible in chip and fetch gates | POSIX and Windows synthetic cases |
| Literal true and `~/...` or `~\...` | Discover and forward raw path; desktop expands its own home | Home policy, Store, service and transport cases |
| New snapshot true to false/absent, or false to true | Replace policy; never OR it with previous state | Store reload and obsolete-load cases |
| Different targets/hosts | No shared policy | Synthetic store cases |
| NUL, empty, over 1024 UTF-16 units, UNC/device/network paths | Refused before content route read; no phone path lookup | Candidate and direct-service cases |
| Relative path, including `../` | Desktop resolves against agent base and makes final decision | Existing discovery retained |
| Missing, folder, FIFO/device, unreadable or revoked access | Bounded desktop refusal; chip eligibility is only a hint | Existing rejection mapping; corrected copy |
| PDF, small base64 response | Decode `pdf` and bounded bytes; only this kind reaches PDFKit, never the SVG/text branches | Synthetic response and `pdfBytes` cases |
| Valid, malformed, zero-page or password-protected PDF | In-memory PDFView; otherwise a named failure with Try again, never a password prompt | Hosted synthetic PDF cases |
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

## Caps

The merged desktop sniffs `%PDF-` at offset zero before text, uses `application/pdf`, and caps local PDF preview bytes at 16 MiB. Annex still caps binary at 8 MiB, omits oversized base64 and returns `tooLarge`. Go's existing 12 MiB encoded and 8 MiB decoded limits remain unchanged. Boundary payloads in tests are built in memory rather than committed as large files.

## PDF preview

Issue 187 accepts PDFKit rendering or Share/Open In. Go renders with PDFKit and does **not** add Share or Open In: no temporary file, share item or `Transferable` export, so there is no new file ownership or cleanup. An earlier draft of this plan listed Share/Open In and temporary-file ownership as deferred together with PDFKit; they are not delivered and not required.

- `CompanionContent.pdfBytes` admits only `kind == "pdf"` without `tooLarge` and at most 8 MiB of bytes. This repeats the existing decoded-byte ceiling at the PDFKit entry point, including synthetic or injected content; it does not bound PDF rendering memory or time. Unknown kinds are already normalized to inert `other`, and MIME never selects PDFKit.
- `PDFDocument(data:)` opens those bytes in memory; the document has no URL. A nil, locked or zero-page document throws a named `unavailable` error. Like the image decode failure, it offers Try again, because the desktop file may have changed. Go never asks for a PDF password.
- `tooLarge` keeps the 8 MB message; a `pdf` without bytes keeps the generic unsupported-format text.
- Lifecycle reuses the sheet's load generation. `load()` clears the document before every fetch, including Try again, and assigns it only after the existing cancellation and `loadID` checks, with no suspension between those checks and the synchronous parse. Disappearance invalidates the generation and drops the document. `.sheet(item:)` gives a different reference a new view. `dismantleUIView` removes the document from PDFView before its delegate.
- PDFView retains native scrolling, zoom and text-selection facilities. Same-document navigation, rendered usability and VoiceOver interaction require actual native validation; extracted text is not accessibility acceptance.

### Native actions

PDFView.h (iOS 26.0 SDK) documents the URL-link callback's default as opening the URL with the system, and the remote go-to default as a beep. `CompanionPDFPreview.LinkGuard` implements both as separate no-ops. PDFView holds its delegate weakly; SwiftUI keeps the coordinator from `makeCoordinator` until `dismantleUIView`.

| Surface | Handling | Evidence |
| --- | --- | --- |
| URI link or widget action (`PDFActionURL`) | `pdfViewWillClick(onLink:with:)` no-op | Header default; hosted routing control and guard installation |
| Remote go-to (`PDFActionRemoteGoTo`) | `pdfViewOpenPDF(_:forRemoteGoToAction:)` no-op, distinct from URL | Header default; hosted routing control |
| Launch | PDFAction.h describes a PDFActionURL representation; that does not establish callback routing | **Unverified**: no synthetic Launch fixture or suppression claim |
| Same-document go-to; named page/zoom actions | Native PDFKit behavior is retained | Not exercised by the proposed tests |
| Named Find / GoToPage | Optional callbacks not implemented; iOS default undocumented | Unverified; no action-containment claim |
| Named Print | No iOS delegate callback; behavior undocumented | **Unverified**; no inference about its effect |
| ResetForm, editable form fields | Native behavior is retained; app adds no save API | App performs no explicit write; native interaction remains unverified |
| SubmitForm, JavaScript, ImportData, sound/movie/rendition | No public PDFKit action class; behavior undocumented | **Unverified**; no claim that they are suppressed |
| Long-press or context menu on a link | Undocumented; could bypass the delegate | **Unverified**; needs a tap-level UI test |
| Text selection menu (Copy, Translate, Share, Search Web) | System actions on selected text, after explicit taps | Same as the existing text preview's `textSelection`; not changed |
| Data detectors | App does not configure the deprecated view-level property | No inferred default or suppression guarantee |

These rows make no claim beyond the evidence shown. Before release, a fixture-mode UI test should tap and long-press a URL link in a synthetic PDF and confirm the app stays foreground with no Safari launch.

## Ownership

`CompanionPDFPreview.LinkGuard` is a new MainActor class, so the Debug binary gains an isolated deinit. It is recorded as `main_actor` in `scripts/isolated-deinit-policy.json` and in the [ownership table](isolated-deinit.md). It has no stored fields or captures. This retains the compiler's teardown; it is not an ARC-only exemption. At exact base `cd9d60e8`, the policy has 28 ARC-only, 16 main-actor and one generated entry (17 retained isolated paths). This candidate adds one main-actor entry, yielding 18 retained paths; earlier 12-path documentation is historical, not the current count. `PDFDocument` and `PDFView` are Objective-C classes with no Swift isolated deinit. The view adds no owner, task, file or callback beyond them.

## Change and validation sequence

1. Commit this plan and focused test changes first. They describe APIs introduced by the second commit and are intentionally not claimed passing in isolation.
2. Extend `CompanionContentRoots` with strict default-false `anyPath`; decode it with each snapshot. Carry it separately through archive page/transcript and pass archive context to the existing preview/store gate. Preserve generation checks, current host gates and server authorization. Normalize unknown kinds after the existing validation and correct roots-only copy.
3. Review diffs and parse touched Swift sources only. No builds, typechecks, tests, simulator/device/live/provider runs or fixture refreshes are authorized in this task. Parsing cannot establish type correctness or runtime behavior. In particular, package tests exclude `Views`.
4. Parent reviews source, including the PDF preview and its ownership entry. Execution validation requires a later serial Dispatcher allocation; full issue acceptance remains with the parent.
