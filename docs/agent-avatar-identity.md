# Agent profile image precedence

Go uses quick bolt → saved profile image → emoji → initials in the shared
`CompanionAgentFace` resolver. `CompanionIdentityFace` renders that selection for
agent avatars and routed sender identities; the chat header can reuse it without
a separate resolver. Mason explicitly requested that a custom image win when both
image and emoji are set. This supersedes the desktop's previous emoji-first order.

## Static source provenance

Inspected desktop commit **5337b48ccb21cde32ee3d28ed9cade7d5fde261f**, cloned
read-only for source inspection inside this worktree; no desktop or provider ran.

- [`src/shared/types.ts:80–90`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/shared/types.ts#L80-L90)
  defines `Agent.icon` as a filename in the agent-icons directory.
- [`AgentSettingsView.tsx:254–265`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/renderer/features/agents/AgentSettingsView.tsx#L254-L265)
  picks an image, crops it and saves the result. The
  [`agentIconSlice.ts:12–24`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/renderer/stores/agent/agentIconSlice.ts#L12-L24)
  records its filename and image bytes.
- [`agent-config.ts:3505–3525`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/main/services/agent-config.ts#L3505-L3525)
  saves the cropped image as `agentId.png` and sets `agent.icon`. It does **not**
  clear `agent.emoji`, so coexistence can occur despite the mutually exclusive
  comment on the `Agent` type.
- [`appearance-service.ts:286–318`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/main/services/appearance-service.ts#L286-L318)
  also lets an authorized caller explicitly select a profile-image file using
  `imagePath`. This path clears emoji when setting the image.
- [`annex-server.ts:873–908`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/main/services/annex-server.ts#L873-L908)
  populates `agentIcons` and `iconRefs.agents` from durable/Dispatcher `config.icon`
  files through `agentIconFilePath` and `readIconImage`. The
  [`agent icon endpoint:1595–1615`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/main/services/annex-server.ts#L1595-L1615)
  resolves the same saved profile image.
- [`AgentAvatar.tsx:66–67`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/renderer/features/agents/AgentAvatar.tsx#L66-L67)
  describes provider identity as a separate neutral `OrchestratorGlyph` beside
  the model. Provider glyphs and generated initials are not inserted into the
  profile-image maps.
- [`agent-avatar.ts:51–59`](https://github.com/Agent-Clubhouse/Clubhouse/blob/5337b48ccb21cde32ee3d28ed9cade7d5fde261f/src/shared/agent-avatar.ts#L51-L59)
  retains the desktop's previous quick → emoji → image → initials order. Go's
  intentional image-first change follows Mason's explicit requirement.

Thus a catalog agent reference already identifies an explicitly selected profile
image; no custom/provider discriminator needs adding to implement this precedence.
The wire does not distinguish a human's cropped upload from an agent-selected file
or reveal how the file's artwork was created. Go does not infer those origins from
filenames, hashes or providers: either selected file is the agent's profile image.

## Recorded desktop fixture and intentional Go difference

The canonical [`sender-identity.json`](https://github.com/Agent-Clubhouse/Clubhouse/blob/4b3b4f59e67adcbe9df477b5f091ae1d9fb81953/test/fixtures/annex-mobile/sender-identity.json)
is pinned by `Tests/Fixtures/AnnexContract/SOURCE.json` to desktop commit
**4b3b4f59e67adcbe9df477b5f091ae1d9fb81953**. Its `emoji_over_image` name, input
catalog and recorded desktop expectation stay unchanged: `durable_chat` has both
`durable_chat.png` and 🦊, and the desktop's recorded face is the fox on
`#6366f120`. The contract tests explicitly assert that expectation and provenance.

For that specific documented input, Go expects `.icon` because of Mason's custom
profile-image priority. Before asserting Go's rendering, the tests independently
require the original catalog image and both raw identity fields. They substitute
the same valid synthetic raster in memory and require its known SHA-256 version,
`b1ff9c8ea3a780bad09b346c423d2d0e46815926879b18e841d928376a946640`, on the resolved
identity. A lost decoded icon or a wrong version fails those checks. Expected
rendering never branches on the actual resolved icon/face, and all other recorded
desktop face checks remain in place.

The synthetic Dispatcher sequence retains an emoji-only positive control, then
checks coexistence → image-only → image removed, including the expected byte
version, current row/sender identity, resolver invalidation and REST refresh
preservation at each step. It changes no canonical fixture bytes.

## Test plan and boundaries

- Domain `CompanionAgentFaceTests`: image and emoji coexistence selects the image;
  quick still wins over both; emoji alone, empty emoji and no image keep their
  fallbacks; routed sender uses the same resolver and changes identity when an
  image version changes or an image is removed.
- Contract tests preserve transport/identity fields and the recorded desktop
  expectation, with the single documented Go coexistence override above. The
  Dispatcher sequence separately verifies emoji-only rendering and image removal.
- Hosted `CompanionProfileImageRenderingTests`: synthetic red and blue PNGs use
  the real bounded cache and `CompanionIdentityFace`; sample pixels to prove the
  image beats a coexisting emoji and a replacement version repaints the same face.
  An unavailable version falls back to solid rose initials, rather than retaining
  the old image or showing the emoji. No snapshot uploads or remote fetching.
- Existing icon store/reference tests cover invalid image admission, missing and
  stale versions, response validation, cache limits, cancellation and replacement.
  The cache, version-keyed SwiftUI task and image-failure initials remain unchanged.
- Project icon rendering stays independent and unchanged.

## Validation evidence and remaining checks

At exact `4f7e4aeb6f46360976f0ed8734b52bd5b3078477`, the six filtered AgentFace
test functions passed, as did a Debug build and the two hosted avatar cases once
each. The direct shared-face test verified real image precedence, version change
and fallback. The older Dispatcher smoke's Image attachment nevertheless showed
initials in both consumers; its dimension-only assertion was insufficient. That
original evidence stays separate, and its fallback's cause remains unproven.

At exact `6f0f7c22c6b0caf565750007769efa570038c342`, one four-job Debug build and
the same two hosted cases passed serially, once each, without retries. The
strengthened Dispatcher assertions measured 710.22 square points of cyan profile
pixels in the row and 436.89 in the sender; inspection confirmed the image in
both. The owned simulator was deleted and the build/test processes drained.

The ordinary exact-6f [CI package job](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/42169721688/job/127734522625)
then failed three legacy emoji-over-image expectations: the two sender fixture
consumers and the Dispatcher appearance sequence. Its failure log is preserved;
the new AgentFace suite passed. The tests/docs correction above addresses those
expectations without changing production code or desktop fixtures. Its validation
is limited to Swift source parsing and `git diff --check` until a new serial slot
is allocated. Package tests, build/type checks and hosted checks have not been
repeated for the correction; earlier-head passes do not validate it. Combined
header proof and remaining full validation stay with the orchestrator.
