# CI attribution after the hosted history fixture repair

Source head: `d526b066e72c698625192feffafd0b693b3f4e91`. Prior product-proof head: `fab40073358820b4fcd75d73819ccb04fb096111`. Baseline main: `85ee757ae3de9d962d0cafab81ad0011314522ab`.

The local phone and iPad eight-method class proofs passed once each on iOS 26.0 and received separate structural and private-originals review. They do not establish hosted iOS 26.5 acceptance. The frozen manifest and executed-runner discrepancy remain documented in `runtime-structural/execution-provenance.json`; the executed manifest is unchanged.

## Prior CI1131 findings

| Signature | Observation | Attribution boundary |
|---|---|---|
| Hosted History two methods | Phone job 135300318198 and iPad job 135300317904 fail the old global-coordinate fixture checks | d526 changes only those fixtures; original 1pt semantic/native-top bounds remain. Hosted rerun pending. |
| Permissions landscape :74 | Main job 135269619022 reproduces identical title mismatch three times | Pre-existing, tracked in #588; no permission changes here. |
| Dispatcher grant-to-Needs-you :179 | Main job 135269618969 also fails three times | Pre-existing signature, tracked with #553. |
| Dispatcher sender-fold timing | Head partial log fails twice before passing its third automatic workflow attempt | Existing #553 class; the cancelled shard has no completed passing result. |
| Long-name header :327 | Head other job 135300318065 clips host tag, then passes its next automatic attempt. Main other artifact 135269618985 clips name/status at the same assertion and pane height, then passes its third attempt | Same assertion family on main; exact head host-tag field is not baseline-proven. |
| Home native menu XXXL watchdog | Head other first attempt exceeds the 240s allowance while actively traversing public AX menu ancestors. Main method passes in 402.639s across two app launches; each launch resets the allowance. Head second attempt has no completion in the cancelled log | Exact head timeout remains unclassified. Timing/AX traversal cost is a hypothesis, not a product-independent verdict. No allowance or assertion changed. |

Both cancelled other-shard bundles contain Staging/Data but lack final metadata. Official artifact digests were verified before safe extraction. `xcresulttool get test-results` cannot read their summary/tree/details (rc64). Originals were not repaired. Partial logs cannot be promoted to a complete once-only result. Raw logs, screenshots and original native containers remain private.

## Current CI1139

[Run 44479002209](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44479002209) pins d526. At this update, Plan and Release have passed, Debug has started, and packages remain queued. Hosted 26.5 lanes and inherited/cancelled signature attribution remain outstanding. Ready is a review state, not a claim that CI passed.

Artifact collection and read-only extraction used separate bounded guarded FIFO tickets; both closed with no owned processes, simulator actions or swap growth. No runtime installation, manual CI retry/cancel, assertion weakening or product change was used.
