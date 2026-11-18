# #582 harness-r2 / rebase review — BEFORE any build

Source5c785b864c4fe706c0b37765672fa9ece0e4283d on main85ee757ae3de9d962d0cafab81ad0011314522ab. Rebase-only heade9337fcc had a BYTE-IDENTICAL full cumulative patch to a971c9343 on77b24899: SHA5bdaa4d7. No conflict. Then the correction changes ONLY the DEBUG recording fixture, its new UITest file and the design/proof doc. Every other #582 app source file is byte-identical to a971. No inset/comparator code or run exists.

#587 identity: original ReadingUITests SHA6c5749d41ba1670ac001c65428016333d7c0818af7f9ea44d3579f980c7784b5 equals main85ee exactly. Its delta from77b equals the85ee #587 commit only. Other3 original contract hashes unchanged. #588 permission-controls product file is outside our cumulative diff. Full proofs in rebase-85ee-identity.json; pre-rebase-a971.diff; harness-r2.diff and cumulative.diff.

F-r1's product-bug classification is explicitly SUPERSEDED: native topInset already covers the banner. First paused encoded frames show the button clearly; A's accepted38pt adjustment subsequently puts the inline header above the viewport. No product layout change is authorized or included, and NO main comparator is authorized/run. Old proposals/report remain as labelled history with the revised ruling attached.

Harness-only hunks:
- DEBUG action strip becomes2rows x6 native buttons, all12 actions/identifiers retained. Short captions, fixed12pt test-control font,44pt minimum label content; this affects ONLY DEBUG recording controls. The actual product gets the remaining offered viewport, explicitly disclosed. One native tap/action and real target transition; no rescuing scroll/retry.
- F2 first issues ONE existing native status-bar top action. Whole earlier control must fit within the public native vertical scroll-indicator track and the track must start below the real banner button, then actual prefix-change/tap. This uses real native viewport geometry and no guessed banner padding. Spoken label Show earlier messages and identifier companion-show-earlier are asserted unchanged. All4pt prepend/tail and6pt restore checks remain.
- F3 generic descendant composer query and the same software-keyboard setup copied from the existing Reading helper. Original ReadingUITests is not edited.
- External first-frame VIDEO gate now explicitly includes the button fully visible below pinned banner, before A, on all4 routes. Later AX cannot rescue it; accepted later A movement is still bounded by header/padding/saved-distance+6pt and canonical entry remains partially visible.
- Extra FSE1 (SE portrait), FAX1 (ProXXXL portrait) each records a fresh paused opening requiring the first-frame button/canonical content and then validates native-top label/id/clearance. FL1 is a landscape DIAGNOSTIC recording, with#483 exclusion explicitly stated; no landscape layout/first-frame credit. Setup/actual execution still must succeed once.

Exact order: fresh A900; F3Pro600; FSE1/300; FAX1/300; FL1/300; independent video QA before N13/600; H15methods19executions/600; S2/600; CPU3methods per side (fresh builds900, hosted480); C23/C50/R0/RSE; D current-main coverage1200. Expected outcome maps unchanged. Fresh labels/DD/bundles/sims; STOP no assertion retry.

CPU r5: main overlayef6d9247 on85ee; headf266922a on5c785b. Full additive testSHA1606d1b7 and DEBUG hook additions581677ae unchanged from approvedr4. Main/head products and manifests updated/re-pinned; preparedRowCount max/total, body/timeline<=main per opening. Home per-step and paused per-batch <=main. CPU time supporting only (>20% with equal counts non-blocking flag). Old CPU configs preserved/stale; none has run for this design.

All required diffs/source hashes/counts/configs are here. NO build/test/simulator on this rebased head. QA exact review required before fresh A. Parent owns landing; PR584 stays draft/device check deferred.
