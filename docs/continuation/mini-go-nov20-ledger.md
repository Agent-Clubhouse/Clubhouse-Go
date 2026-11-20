# Mini Go assignment ledger, November 20

Owner: Mini Go orchestrator `durable_1795018744048_zk993w`.
Repository: Agent-Clubhouse/Clubhouse-Go.
Source ledger: `Clubhouse-Go-Helper/nov20-continuation` at `6703d2d4abf11c637817214d09acf7db38c07840`, file `docs/continuation/nov20-go.md`.
Snapshot: 13:46 UTC.

Mini Go accepted every offered scope explicitly. It accepted each one only after the laptop writers stopped and Mini Go fetched the exact refs from origin and rechecked them. All 24 frozen pins in the source ledger matched `git ls-remote origin` at 12:3x UTC. Acceptance confers no landing, release, infrastructure or native authority.

## Frozen intake (unchanged since acceptance)

All 24 refs in the source ledger's "Final laptop freeze and Mini intake" table remain on origin at their frozen commits, except `go-feedback-review/integrate-ci-links`. Mini Go advanced that branch (see below). The four final owner briefs are:

- `go-feedback-review/nov20-continuation-notes` `8bae9a34b975c9da797fd3bda5085603e2c11851` STOP.md, SHA-256 `892ec8af4f730af22d810fa8673ac7ed4ffe93cf2b21f60c913167367d76d8e9`
- `ux-root/continuation-nov20` `c749cfffc755fc147489015393ddc809455d2b81` ux-root-final/index.json, SHA-256 `09a11be058899a3e89bea9827d4665228e4c7defe06cb286983c5f77e6c7d899`
- `bold-gazelle/go-bug-pass-nov20-continuation` `e7b0c35f1849da3375c2a6e41bbfe022993b463b`, brief SHA-256 `27be880d033c4cee12eabff7fbd3e13df8e0affad974c85ad257337bb3d82cd4`
- `bold-gazelle/proof-runner-continuation-nov20` `c4beeb8c1883759bc4c78d328f7040fb543f9b0f`

## Mini-origin work since acceptance (all pushed)

| Branch | Commit | Status |
|---|---|---|
| go-feedback-review/integrate-ci-links (PR #620 head) | `6bba2f744815104f91ce21b5e56fb1010bb2bcb5` | Plain fast-forwards: ab6c7149 → 45017f8d → 6bba2f74. The independent review of ab6..45017 passed. |
| go-feedback-review/integrate-620-compile-fix | `6bba2f744815104f91ce21b5e56fb1010bb2bcb5` | Changes 3 lines in the diagnostic: `NSStringFromCGRect` becomes `NSCoder.string(for:)`. |
| mini-go/preview-not-shared-fix | `47e230577d3d51219b01f075aadf2c3a1d64e1c4` | Test-only change on top of #617 f65b1297. It brings the assertion in line with the copy that #617 changed. It will be applied to #617 after #620 lands; #619 inherits it. Hosted-unverified. |
| mini-go/transport-starvation-fix | `efddee52e30d263b53cbd940350775fc687c8bc4` | Repair for #611/#622 on top of 6bba. The waiter now uses the manual clock and wakes on state changes instead of wall time. Review pending. |
| mini-go/nov20-ledger | this file | Mini ledger. |

## Hosted results on the integrated head

- Run 44736042177 on 45017f8d failed at compile time (Build for testing). The `NSStringFromCGRect` calls carried in from the never-built f3befc diagnostic are unavailable on iOS. Swift packages failed on one test, `TransportFailureModeTests silenceAloneDoesNotPutASlowInitialSnapshotOnADeadline` (`:504`). The c538 timing shows a 1 ms sleep that took 10.49 s while the condition itself was immediate: scheduler starvation. No UI tests started.
- Run 44738003005 on 6bba2f74 is in progress. Build for testing, Release, iPad hosted, and the chips, dispatcher/settings, grants/projects and decisions/linked home lanes passed. Swift packages and the feedback diagnostics lane failed. The other lanes are still running. The first-outcome table comes from the integration helper.
- Job 136210713696 (#616, 434e) was cancelled at about 55 minutes. The archive-header method never started. The first failure was a CompanionAccessoryUITests launch timeout on 3 of 3 iterations. The log is preserved privately on the Mini (SHA-256 `20b93d388f5755595821eb2ddc89fe4f9d208f1856f3a0b7187cbeda3832ed57`).

## Preservation and dependency classification

Source transfer gaps: none found. Every source, WIP and owner-notes ref named by the laptop is on origin at its frozen commit and has been fetched and verified on the Mini.

Intentionally omitted, kept private at the laptop (passive custody): native compiled products, raw xcresult bundles, screenshots and media, private run configurations and harness inputs, and path-bearing review blobs. Work that needs these originals stays DEFERRED. A fresh run on a capable host can establish new evidence. None of this blocks hosted CI work.

Private text evidence held on the Mini, in `/Users/masonallen/continuation-evidence/2026-11-20` (mode 0700): the six transferred records (160,124 bytes), each hash-verified, and the job 136210713696 log plus its record. These files are not published.

Execution blockers:

- Local simulator proof on the Mini is BLOCKED. Simulator package setup needs authorization, which was not granted. There is no install or retry. All native evidence comes from hosted CI.
- #622 private controller history and genuine restart need desktop host support.
- Native menu 6179 acceptance is DEFERRED. It is excluded from the integration.

Mini-origin unpushed WIP: none. Helper workspaces hold only local `.mcp.json` and `CLAUDE.md` configuration edits.

## Next

1. Finish the first-outcome record for run 44738003005 and classify each failure.
2. Review the transport repair and apply it to #620.
3. Repair the remaining first failures by owner area.
4. After #620 is green and landed under existing authority: apply the preview fix to #617, rebase #615, #621, #606, #607 and #612, and re-establish the #616 and #622 hosted outcomes.
