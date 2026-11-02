# Long Dispatcher chat: test plan and evidence

Compare build 147 (`6c32b12`) and main (`ec99721`) with the same release-mode package workload: 1,000 and 5,000 routed deliveries, every twentieth delivery a long folded Markdown part, followed by 200 text chunks. Time projector application, full store replacement and timeline construction independently. Timings are observations on this Mac, not phone frame-time claims. Keep deterministic assertions on output parity and amount of processed work.

Regression plan: streamed/final text matches history; replay and session changes; queued burst boundaries and transitions; earlier-page window identity; Copy message and expansion state remain tied to original message IDs. Run package coverage and ratchet, app Debug and Release builds, app unit tests, preview and Dispatcher UI tests, and the long-reply scroll test on a newly created private simulator. Never run the live E2E script or touch the host app, shared simulators or physical phone.

Known limits: a package seam measures model work, not SwiftUI body executions, scrolling, typing, image decoding or physical-device memory pressure. Payload bytes are logical UTF-8 lengths, not heap allocation measurements (Swift strings and arrays may share storage). Network timings from the reported phone session do not measure main-thread/render cost.
