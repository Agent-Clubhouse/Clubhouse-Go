# #569 Reading restore evidence — work in progress

Original controlled failure evidence only. No new #569 build or test has run yet; no product fix or acceptance is claimed.

Main e45aef3b plus the byte-identical CompactComposer overlay, original50 prefix, failed at y113 versus saved209.6667 with the unchanged6pt tolerance. Product-reported arrival preceded the failing read by approximately2.85s. The raw outcome line is un-timestamped; adjacent timestamped mount/phase lines plus its duration bracket it.

- [Contact sheet, final16seconds at1fps](original-e45/original-e45-return-frames.png)
- [Extracted product trace](original-e45/original-e45-reading-product-trace.txt)
- [Original test activities and exact read times](original-e45/original-e45-reading-activities.json)
- [Original finding and checksums](original-e45/diagnosis-before-run.json)

Original complete xcresult remains at `/tmp/go-footer-560/T566-main-20261118T005931Z.xcresult`; recording is `evidence-T566-main/0A47338C-9454-4917-8D77-DE2DF4CBEE96.mp4` there. Full diagnostic export is local; these excerpts preserve the relevant evidence without publishing unrelated test output.

The entry-anchored bookmark versus a fixed content-offset/window shift (H1), and a save during teardown (H2), remain hypotheses. One historical b829prefix23 confirmation with public-frame stability, followed by one separately reviewed main DEBUG-only logging run, is pending. All six-point checks remain unchanged. The DEBUG logging branch is diagnostic only and must not merge as a product fix.
