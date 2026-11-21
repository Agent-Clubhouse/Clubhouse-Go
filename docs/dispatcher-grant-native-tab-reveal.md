# Dispatcher grant return through the native tab bar

The hosted grant navigation case answered the desktop update and removed its
chat request card, then failed to find Needs you. On d5f95a58, the three original
failure hierarchies retain Dispatcher navigation and a collapsed native tab bar
with only selected Dispatch (value `Collapsed, Selected`). Needs you is absent.
The existing waitAndTap stops before any destination tap in that state.

The private grant-test helper now expands only an existing, selected, hittable
Dispatch control whose current value explicitly says Collapsed. It then requires
Needs you to exist within five seconds and be hittable, taps it, and retains the
ten-second Needs you navigation assertion plus the original missing-card check.
An already expanded bar still requires the actual destination tap. No coordinate
substitution, retry loop, tab minimization product change or alternate route is
introduced. Both desktop-update-in-chat cases share this helper; their earlier
setup, grant answer and assertions are unchanged. The original 240-second test
allowance, launch fixtures, shared helpers and all package tests are unchanged.

Original d5 run44867330873 / job136748035291 has three failures for
CompanionGrantRequestUITests.testDispatcherGrantOpenChatSwitchesTabsAndShowsTheRequest.
Complete direct job log: 902813 bytes, SHA256
`1e3dc64203642634a6a4ebb0e947726fb7d3f24cdc319aaedb2d86043c687e49`.
Finalized artifact14697366832: 555108138 bytes, SHA256
`7c18a0b622bf9596a2cd9fd1743ff712f0fcca27d27f8bbc2636a94e1ddadaf6`.
Selected original native accessibility payloads were decoded as data from the
finalized bundle, not obtained by a new app or simulator execution. This is not
a full artifact, movie or pixel review. The older #617 line179 failure establishes
the same failed assertion only; it has no verified same-state attribution here.
Copy-to-draft is a separate finding; its clipboard and persistence cause remains
unresolved. Current87d Recovery/package execution supplies no proof of this fix.

Independent exact-source review and fresh hosted first execution of both shared
helper paths remain required. No local native/simulator run is authorized or
claimed, and no current PR head is changed by this isolated candidate.
