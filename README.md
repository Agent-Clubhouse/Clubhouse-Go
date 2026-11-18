# #569 Reading restore evidence — work in progress

Original controlled failure plus a historical confirmation that did not reproduce. No product fix or acceptance is claimed.

Main e45aef3b plus the byte-identical CompactComposer overlay, original50 prefix, failed at y113 versus saved209.6667 with the unchanged6pt tolerance. Product-reported arrival preceded the failing read by approximately2.85s. The raw outcome line is un-timestamped; adjacent timestamped mount/phase lines plus its duration bracket it.

- [Contact sheet, final16seconds at1fps](original-e45/original-e45-return-frames.png)
- [Extracted product trace](original-e45/original-e45-reading-product-trace.txt)
- [Original test activities and exact read times](original-e45/original-e45-reading-activities.json)
- [Original finding and checksums](original-e45/diagnosis-before-run.json)

Original complete xcresult remains at `/tmp/go-footer-560/T566-main-20261118T005931Z.xcresult`; recording is `evidence-T566-main/0A47338C-9454-4917-8D77-DE2DF4CBEE96.mp4` there. Full diagnostic export is local; these excerpts preserve the relevant evidence without publishing unrelated test output.

The entry-anchored bookmark versus a fixed content-offset/window shift (H1), and a save during teardown (H2), remain hypotheses. The [historical b829 prefix23 confirmation](b829-confirmation-r1/README.md) passed with both returns at saved209.667. The [single main DEBUG-only logging run](main-logging-r1/result.md) also did not reproduce. Neither H1 nor H2 precondition occurred during the deliveries; a real prefix trim occurred after arrival and preserved the entry. No repetitions or product changes. A deterministic fixture is proposed for independent QA. All six-point checks remain unchanged. The DEBUG logging branch is diagnostic only and must not merge as a product fix.
