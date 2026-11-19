# #614 scoped hosted provider outcome

Unchanged head `f76e1cc5aa95bef77c76f15536d8457a24802b8b`; job [135559800568](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44519454645/job/135559800568), attempt 1, terminal success. The original closed job log identifies iPhone 17 / iOS 26.5. All eight routed provider methods have one first-iteration start and one pass, with no failure or later iteration:

| Method | Seconds | Original start/pass lines |
|---|---:|---|
| testGuidedProviderFlowAtLargeText | 91.854 | 2169 / 2529 |
| testGuidedProviderSelectionRequiresSaveAndDoesNotOfferResume | 86.721 | 2530 / 2810 |
| testProviderApplyAtAccessibilitySizeKeepsSavedProposalAndStartSeparate | 127.425 | 4171 / 4602 |
| testProviderApplyCannotSilentlyReplaceAnExplicitRuntime | 50.176 | 4603 / 4745 |
| testProviderApplyKeepsSavedProposalAndStartSeparate | 87.724 | 4746 / 5090 |
| testProviderApplyLostReceiptStaysLockedUntilItsResultIsChecked | 101.011 | 5091 / 5545 |
| testSleepIsSeparateFromInterruptAndSettingsKeepProviderLockedOnRefusal | 72.361 | 5782 / 5970 |
| testUnsupportedProviderChangesDoNotOfferAnUnsafeGenericMenu | 30.513 | 5971 / 6061 |

The complete selected UI invocation reports 42 tests, zero failures. Original log SHA256 `0b65fcc7db023cbf6a0e42d2cf4e04a1767328fb4f54ce58b67b1ef8c5c7f582` is retained privately with per-method line exports. This is closed-log evidence, not an independent xcresult/container, physical device, VoiceOver or live-provider assessment. Package 55/84 and the independently accepted current-main combined-tree disposition remain separately attributable.

Other lanes retain their actual failures: landscape permission title :74 and AppUpdate :137 each failed the first attempt and two CI retries. Their unchanged-source and historical-baseline observations remain separate from these provider successes. No workflow/job rerun was submitted for this watch.

Parent verified this scoped result and merged #614 as `cadce0a4575227a5ad24a6956f819f42913446d8`. Watch closed; future V2 integration will account for the squash identity against current main.
