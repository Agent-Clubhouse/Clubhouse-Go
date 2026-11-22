# Footer gesture source carry for CI efficiency

This isolated contribution builds on `886dd9edbe83525db07c4a361fb2201e18bcc3f8`.
It carries only the reviewed Footer test helper, not the former #616/#606 work,
Permission changes, product code, settings, provider or credential changes.
Those assignments and refs remain parked. The original #629 full run stays on
`f7a483f5c38c863711717f3e18280fcd4bc3820d` and remains its own evidence.

The target's entire old Footer file is blob
`291e543b93ff612da9dfeb6470be188aad72f1e1`. Its new entire file is the already
reviewed blob `5e1de4427977713e54aaf1df9ffc57d80b6e9a63`, 19503 bytes, SHA256
`0530292a8c14ba41c3a807a924f04200bb7cd76066bcbfdbaa08e67b088ecfd0`.
The exact delta is 28 additions / 6 deletions: three private gesture helpers and
two `try` call sites. Every original test identity, assertion, pixel/OCR guard,
140-point cap, press/velocity/hold, five-second paused-state wait and allowance
is retained. The gesture starts and ends within the measured visible transcript
above the footer/keyboard, instead of using the full accessibility scroll frame
that extends behind those overlays. No native scrolling or recognition is inferred
from source geometry alone.

The genuine existing source review is
`6b5527f4471da06f23a9f58310fd48ea99e3071b`, 6689 bytes, SHA256
`407d0938358b3ed25cdeb3bd00d7b1c3f8786ab6870640b8a53738afce4da3ed`.
Its original-session attribution, timestamp-filter limitation, Foundation-only
controls and source-only scope remain intact. The previous target applicability
review `9b631de745b41c02aa7fb8da0fa6d520aa525d8e`, 7624 bytes, SHA256
`17ed21f468a901aa1a6ab5a8c7b5f41cddf42c5edd1acf008fe7ef15aa023946`,
is reference material, not new-target acceptance.

All four bound dependencies remain byte-identical on the new target; the composer
also equals the previously reviewed target (not a new Send-style acceptance):

| Source | Blob |
| --- | --- |
| UITestSupport.swift | `2d57d7e9dcb4cc08093e76dbb6553369cdea6563` |
| CompanionChatControlsBar.swift | `7f5f426c542ac4e8da2da95d26bf07b62c48cd6c` |
| CompanionConversationView.swift | `db98a5656b8dde09f1980055c6f320dd08dd0e6d` |
| CompanionConversationGrantRequests.swift | `9513e92eb2ef9087aee09d45e2a7638fe42a5947` |
| CompanionConversationComposer.swift (equals prior9ceb target) | `eb1dcfa28d969c445636f4c2485bf4e22a200cab` |

In current original Other job 137026198423, Dark failed three attempts at line187:
50.790 / 41.974 / 57.502s; Light failed three at that same reading-state assertion:
62.342 / 42.067 / 57.618s. Before the first Dark failure, logged keyboard-up
geometry has footer top419, composer429..529 and keyboard top539, matching the
reviewed context. These sequential records do not independently establish the
current gesture recipient or pixels. No root-cause exclusivity or cure is claimed.

On the next necessary hosted candidate, preserve Dark and Light first outcomes,
durations, all reached or unreached oracles, gesture records and retries. Do not
credit any time saved before measurement. The independent overflow pixel failure
at old line273 is outside this helper's fix claim; do not absorb it, relax its
threshold or treat a future reading-state pass as overflow acceptance. All original
failures, complete workflow/coverage/inventory gates and missing IDs remain.
