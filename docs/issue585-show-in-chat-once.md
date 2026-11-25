# Consume Show in chat once per request

Refs #585, #609.

The conversation parent now owns request admission across transcript mounts. A request made before a transcript appears stays pending. Once the transcript resolves the real item and is ready to begin navigation, the parent records that UUID as consumed before any suspension. The task retains its input identity until it finishes, so acknowledging it cannot cancel its own restoration. A matching completion clears the pending request; an older completion cannot clear a newer request. Cancellation after admission consumes that action. Visiting the same item again requires a new human action and UUID.

This changes navigation-request consumption, not decision authority. It does not answer an approval, alter the transcript restoration algorithm, change its deadlines, or replace the person's later saved reading position. Consumed UUIDs live only in the conversation parent's in-memory lifetime.

## Proof

On main c9f612ddc, the hosted cardinality regression observed the original third jump: `[first, second, second]` instead of `[first, second]`. The other 12 ReadingOpening tests passed. The corrected hosted tests retain the first reveal, parent reevaluation and new-request checks, then verify remount does not replay the consumed request or replace a later saved bookmark. Two additional cases exercise cancellation during restoration and a new request arriving while an older restoration is cancelled. Five package tests cover admission, hidden requests, rapid remount, new UUIDs and stale completion/requeue ordering.

A first native tab-return harness stopped before return: pushed chats intentionally hide the root tab bar. That is retained as a test-route failure, not a replay or product verdict. The final native scope uses the existing real pinned-decision Show-in-chat control and original-context geometry test. The hosted mount tests supply the replay/cancellation evidence; the native test does not claim to exercise a hidden tab bar.

## Feedback invitation placement

#609's product correction already landed in 12ff4288b through #612. The current app root has no renewal safe-area inset. Settings > Feedback options > Invitation & enrollment retains the accessible status and renewal route. This change does not reimplement that correction or change feedback enrollment, transport or preferences. The existing five native renewal tests cover expired standard/XXXL, offline, access-required and connected states, keyboard/composer geometry, navigation and repeated Settings/enrollment dismissal, and byte-preserved enrollment/queue/preferences/request counts. Existing hosted status tests distinguish checking and unavailable states.

Fresh simulator results and exact evidence pins are recorded in the PR and the private author packet. Local simulator evidence does not establish physical-device behavior, real invitation issuance, or a real desktop's decision execution.
