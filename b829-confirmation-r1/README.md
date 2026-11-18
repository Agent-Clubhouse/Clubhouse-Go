# Historical b829 confirmation — not reproduced

Product b829a226 with only the reviewed public-frame stability helper (6e84c4c8). Original 23 selectors, original execution order, exactly one run each. Result: 20 Passed, 2 existing strict Expected Failures, 1 pointer-wheel skip, 0 unexpected failures. The target passed; no product fix is claimed.

Both return checks first observed the chosen marker at the saved y=209.667 and stayed there through the stability window. The two app restore arrivals are extracted from the app stdout, with adjacent timestamp brackets because the original print has no timestamp. They took 155.710ms and 174.633ms, one delivery attempt each. The raw frame timelines and unchanged 6pt checks remain available in the result bundle.

Timing limitation: admission was 85.41% idle, but the parent observed heavy host load during the run (load 40, 5.7% idle). Runtime resource measurements were record-only. This passing observation does not rule out the intermittent failure in earlier prefixes, nor does it discriminate H1 from H2 without the diagnostic overlay.

The exact owned simulator AF698760-A126-4607-A6AB-C0A5EE93B6D5 was shut down and deleted. System-wide 0 Booted, no owned processes, swap growth 0. Full bundle retained locally at /tmp/ux-569-proof/tickets/c-confirm-r1/tests.xcresult.
