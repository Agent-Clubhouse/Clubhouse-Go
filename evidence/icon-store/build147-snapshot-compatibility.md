Archived from icon PR214 commit `03f51504b5bdd0aac65492aa8d33b5a0c9877907`, `docs/testing/build147-snapshot-compatibility.md`.

# Build 147 snapshot omissions

Validated exact Go commit `6c32b12`, not the current implementation. An archived tree
under `build/build147` ran the audit test with SwiftPM; no app was installed or launched.
The test encoded JSON, decoded `AnnexEnvelope`, delivered it through the scripted
transport to the real `CompanionLiveService.receive`, and waited for `applyCatalog` to
apply a distinct project name. Every case retained one project and agent and stayed
connected. No listed shape caused a decoding error or `malformedResponse`.

| Field | Absent | `{}` | `null` | `[]` | Required by Go 147? |
|---|---|---|---|---|---|
| `canvasState` | Accepted | Accepted | Accepted | Accepted | No; ignored |
| `appCanvasState` | Accepted | Accepted | Accepted | Accepted | No; ignored |
| `bulletinDigests` | Accepted | Accepted | Accepted | Accepted | No; ignored |
| `plugins[].contributes` | Accepted | Accepted | Accepted | Accepted | No; ignored |
| `snapshotTruncated` | Accepted | Accepted | Accepted | Accepted | No; ignored |

An unknown outer `snapshotTruncated` was included too. All proposed omissions together,
with a payload `snapshotTruncated` object (`version`, `reason`, `omitted`, `bytes`), passed
in four shape variants. This does not imply core project/agent fields may be omitted.

The icon tests first seeded both maps so retained and cleared identities are distinct.

| `projectIcons` | `agentIcons` | Decode/catalog/connection | Project icon | Agent icon |
|---|---|---|---|---|
| Absent | Absent | Accepted | Retained | Retained |
| Absent | `{}` | Accepted | Cleared | Cleared |
| Absent | `null` | Accepted | Cleared | Cleared |
| `{}` | Absent | Accepted | Cleared | Cleared |
| `{}` | `{}` | Accepted | Cleared | Cleared |
| `{}` | `null` | Accepted | Cleared | Cleared |
| `null` | Absent | Accepted | Cleared | Cleared |
| `null` | `{}` | Accepted | Cleared | Cleared |
| `null` | `null` | Accepted | Cleared | Cleared |

Build 147 replaces both cached maps when either field is present, substituting an empty
map for an absent companion. If both are absent it keeps both previous maps. The desktop
legacy overflow fallback should explicitly send both empty maps to clear prior images.
No claim is made that the proposed metadata-only overflow fallback has shipped.

Reproduction (run from the worktree root; 33 cases in two tests):

```sh
mkdir -p build/build147
# Only extract into a new/disposable directory.
git archive 6c32b12 | tar -x -C build/build147
cp Tests/Compatibility/Build147SnapshotShapeTests.swift build/build147/Tests/CompanionDomainTests/
swift test --package-path build/build147 --filter Build147SnapshotShapeTests
```

The compatibility test is deliberately outside current package targets because it
asserts legacy behavior at the archived commit, including its icon-retention bug.
