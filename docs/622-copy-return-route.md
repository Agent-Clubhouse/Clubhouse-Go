# Routed Copy: return from River after Paste

This successor changes only the return-to-list sequence in
`testARoutedBurstShowsEachSenderAndMessageSeparately`. Real Copy message, system
Paste, the guarded keyboard dismissal and exact 367-byte pre-navigation and
restored-draft predicates remain unchanged. Other callers and tests are unchanged.

On `15845fc4f`, run `45028616815`, job `137228313788`, all three Copy attempts
passed keyboard disappearance and the complete raw-value predicate. Each then
resolved `app.navigationBars.buttons.firstMatch` to
`companion-markdown-block-done`, tapped Done, and failed the River list-entry
predicate at line 381 (100.456/86.405/89.372 seconds). Restoration was unreached.

The first original recording shows River with the pasted draft and no keyboard at
actual PTS 83.4817s (requested 83.5s), a Table sheet at actual PTS 84.6733s
(requested 86.5s), and River again at actual PTS 88.445s (requested 88.5s)
after Done.
These are sampled movie frames, not exact synchronization with SDK event times.
The session log identifies Done at 87.08s. The saved failure hierarchies and
binary snapshots show River's own `BackButton`, label Clubhouse, and the entire
raw composer value in all three processes. Closing Table exposed River; it did
not navigate to Home. The precise opening event and touch recipient that caused
Table to appear are not established by these samples.

The correction closes only the identified Table preview if its named Done is
present. It then requires River's own native Back to be hittable, taps it once,
and requires both the Home list entry and Clubhouse navigation bar, with River
absent, before reopening. Sheet closure and return to the list share one
monotonic ten-second budget. No retry, rescue tap, larger allowance or clipboard
injection is added. The existing reopen interaction and five-second exact raw
restoration predicate remain intact.

Artifact `14758757573` is the original 354,072,392-byte ZIP, SHA-256
`9deb6ffb4cfcdb72203058c2e2b7a26b8b4dc7b9337f4751761786ff02fe6d20`.
It has Data and Staging payloads but no finalized result metadata; xcresulttool
cannot read it. Selected raw stored text/binary payloads and original session
logs were inspected directly, without reconstructing a finalized result bundle.
The original failures remain failures. Syntax and source-retention checks do not
prove the candidate's native navigation; exact hosted execution remains required.

## Other observed failures

WarmZero first failed at the Springboard icon activation/hittability operation
(22.662s), then passed on retry (146.794s). The previous `1b46` original passed
first (143.723s); its entire launch test file is unchanged. No matching baseline
failure or causal attribution to this Copy correction is established.

Sender folds failed first at line 693 while bringing the first Cedar caption
clear before its first fold (340.432s). Its retry reached collapse, native Back,
reopen, refresh and completed PASS in 196.184s before the job was cancelled.
The previous `1b46` original passed first (129.885s). The complete sender method
and all helpers are byte-identical; only earlier Copy test execution differs.
These observations do not establish a sender fix or independent shared cause.
The retry pass does not erase the first failure. Neither failure is changed by
this successor.
