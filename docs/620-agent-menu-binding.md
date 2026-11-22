# Native Home menu binding correction

This child of `25b3f7ece` changes only the native AgentRowMenu test and this note.
It keeps the original clipping panel and original native preview, bound to the
full label of the long-pressed agent (including desktop). Before each reveal or
item check, exactly one existing current collection must belong to that original
panel. It rejects a lost panel, lost preview, changed full target label, missing
collection or ambiguous collections. It never finds a replacement panel globally
or sends another long press.

## Original observations

Run `45042340062`, Scope2 job `137271104529`, artifact `14763732969` on
`25b3f7ece` has three distinct failure observations:

- XXXL attempts 1 and 2 failed at line 24 while locating/revealing Quiet, before
  the long press (109.012s and 42.132s). These setup helpers are unchanged. A late
  frame from attempt 1 shows the Home list with Maple and the Clubhouse section;
  it does not establish why Quiet was not found.
- XXXL attempt 3 opened the Juniper menu, revealed Wake & Resume, then dragged
  within the measured panel while revealing Start New Session. The next old
  collection identity query returned no matches, failing line 30 at 67.036s.
  The recorded frame at actual movie PTS 63.1866667s still shows the Juniper
  preview and menu. The failed query therefore does not establish item activation
  or menu dismissal. The original code short-circuited before checking the panel.
  This supports checking the current child of the original panel; it does not
  prove that UIKit replaced that child or that the original panel survives.
- Default attempt 1 failed its single-press menu wait at line 28 (73.236s).
  Its late recording frame at actual PTS 69.64s shows Juniper chat with no menu.
  This does not establish the touch recipient or why the press failed. The
  294.683s retry pass remains a separate result.

The original menu source on `25b3f7ece` is byte-identical to the previously
reviewed `968935409` blob. These failures remain preserved; this child claims
no correction of the Quiet lookup or first-press failure.

## Retained proof and deferred acceptance

The two test identities, both themes, launch/setup, exactly one 1.2s long press,
initial full action order, original clipping-ancestor selection, strict frame
containment, per-item uniqueness/hittability/enabled checks, standard-size zero
drags, eight-drag cap, gesture endpoints/velocity/holds and timeouts are retained.
The inherited assertion that the original collection AX identity must survive
every drag is replaced by original-panel/original-preview ownership plus one
current child. Losing either original anchor still fails.

Five saved initial native menu hierarchies each contain one Other preview with
the full label matching the long-pressed row. Twelve extracted Swift binding
controls exercise stable/replaced children, changed agent/desktop, lost original
anchors, missing/ambiguous children and the same strict clip. They use real
Foundation/CoreGraphics with fake XCUI elements and XCTest unwrapping; they do
not execute SDK queries, gestures or the app. A source-retention control checks
the untouched helpers/oracles and both test identities. Frontend parsing is
syntax proof only.

Actual SDK identity survival, current-child resolution after the native drag,
both sizes/themes and downstream Details actions require the parent's hosted
proof. No native run, simulator launch, allowance expansion or hosted submission
is part of this correction. Original archive, exports, selected viewed frames,
session trace, controls and hashes are retained privately.
