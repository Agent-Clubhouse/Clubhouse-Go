# Mobile link paths

Audit base: Go main `cadce0a4575227a5ad24a6956f819f42913446d8`. This work fixes
transcript link detection and taps; it does not expand file access, change PDF navigation,
load external resources automatically, or implement #595/#598/#599.

## Creation, display and destination

| Surface | Display path | Tap destination / boundary |
| --- | --- | --- |
| Sent user messages, including past messages | `CompanionChatProjector` → `CompanionMessage.display` → `CompanionMessageView.userMessage` | Native attributed `Text` retains the literal source, adding web destinations and explicit Markdown-link destinations. Copy message still copies `message.text`, including original Markdown/code. |
| Received assistant/system messages and plans | Projector → timeline rows / `CompanionMessageSlices` → `CompanionMarkdown` → native block views | Bare HTTP(S) and labeled Markdown destinations become native link attributes. The conversation's `companionContentPreviews` routes the tap. No URL fetch occurs while rendering. |
| Dispatcher and relayed messages | Same conversation and message rows; `CompanionSentPartView` for routed parts | Same parser/routing. Unsourced and Clubhouse parts retain literal source. Link-bearing short parts expose child links to accessibility; closed long parts still do not construct/parse their detail. |
| Saved sessions | Paired-host archive reader → `CompanionArchivedSessionView` → the same message/block views | Same native taps, with that archived conversation's own roots rather than live-chat hints. Read-only archive behavior is retained. |
| Markdown headings, lists, quotes and tables | Shared attributed inline runs in native blocks/cells | Existing labeled destinations are retained. Linked table cells expose their native links instead of hiding every cell from accessibility. Table/code Open and Copy remain separate actions. |
| Rendered Markdown file | On-demand authorized content → `CompanionMarkdownFilePreview` → shared block renderer | File-only policy still permits HTTP(S)/mailto and internal fragments; relative/local document links and other schemes remain blocked. External actions forward through the inherited URL action. Source and Copy keep original bytes. |
| Markdown Source, other source/code, tool logs and full-event review | Literal native text / read-only source view; code has its own Open/Copy surface | These are literal inspection surfaces, not rendered-link destinations. Code spans/fences, HTML source and image source are excluded from new automatic detection. |
| PDF | Bounded bytes → `PDFView` with its existing `LinkGuard` | URL and remote-PDF delegate actions are deliberately intercepted. This change does not turn PDF links on or claim PDF navigation parity. |
| Welcome / QR settings | Existing native `Link` controls | The explicit website and system Settings destinations retain their existing behavior. Incoming pairing URLs are a separate `onOpenURL` flow, not a transcript-link handler. |
| Endpoint/configuration/status labels | Literal descriptive text | These remain informational values, not automatically promoted into navigation or control actions. |

The original gaps were plain `Text(String)` in sent/unsourced rows and missing bare-URL
recognition in the Markdown parser. Existing `[label](destination)` Markdown already carried
destinations. Detection is separate from native hit testing and from authorization.

`CompanionTextLinks` finds explicit HTTP(S) spans in the original source, excluding code,
explicit links, images and HTML. Only those URL spans are protected as CommonMark autolinks
before the existing smart-punctuation pass. Surrounding prose retains its typography; URL
double hyphens, query parameters and fragments retain their destination. Sent text is never
reformatted. Ordinary messages without a URL marker skip the additional AST scan, and literal
message results share the existing bounded Markdown cache; this is not a measured performance
or memory-reduction claim.

## Files and blocked destinations

The transcript modifier still routes local references through `CompanionContentReference`,
conversation roots and the paired desktop's resolver/content endpoints. It never resolves a
desktop path using the phone's filesystem. Relative paths are candidates for the desktop to
authorize; absolute/home paths require advertised roots or literal `contentAnyPath: true`.
Network/device paths, path-boundary checks, Rich chat content availability, host connectivity,
`chatLinks` capability and server authorization remain independent gates. A displayed label or
link attribute does not grant access.

External chat taps allow only HTTP(S)/mailto. Other schemes and non-navigating anchors are
discarded; no system open is performed for a denied local reference. File-preview rules are
intentionally narrower than chat rules. An installed desktop may lack the advertised setting,
capability or authorized content even when the mobile renderer supports that format. The
separate preview investigation owns improvements to refusal/error explanations; this audit
does not infer an installed host's capability from fixtures or widen safe roots.

Related existing tracking: #135 (availability and blocked previews), #153/#187 (roots/any-path),
#336/#352 (desktop resolution and missing/refused distinctions), #405/#406 (shipped Markdown
Preview/Source), #599 (remaining document parity), and #603 (broader content roadmap). No
duplicate generic transcript web-link issue or active PR was found in the initial search.

## Proof and limits

Focused package tests cover exact destinations, adjacent smart prose, sentence punctuation,
balanced parentheses, Markdown emphasis versus URL asterisks, labeled links, Unicode/CRLF,
code-adjacent prose, file policy and ordinary no-link messages. Earlier parser failures are
retained as regression evidence, not erased by later passing results.

`CompanionTextLinkUITests` uses real conversation and archive views, native text/link gestures,
and the production routing modifier. Its DEBUG-only preview fixture intercepts only the final
inherited system-open action and records the URL and count. It does not replace a link with a
fixture button or open Safari/network destinations. Cases cover sent/received/relayed/Dispatcher,
saved messages, tables, Markdown files, inert code, blocked schemes/outside paths and an
authorized desktop-preview route. Native results remain pending until the exact candidate is
built, executed under shared resource admission and independently reviewed. No physical-device,
installed-host, release or PDF-tap acceptance follows from these local checks.
