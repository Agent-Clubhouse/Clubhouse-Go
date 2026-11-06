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

## Test plan and boundaries

- Domain `CompanionAgentFaceTests`: image and emoji coexistence selects the image;
  quick still wins over both; emoji alone, empty emoji and no image keep their
  fallbacks; routed sender uses the same resolver and changes identity when an
  image version changes or an image is removed.
- Hosted `CompanionProfileImageRenderingTests`: synthetic red and blue PNGs use
  the real bounded cache and `CompanionIdentityFace`; sample pixels to prove the
  image beats a coexisting emoji and a replacement version repaints the same face.
  An unavailable version falls back to solid rose initials, rather than retaining
  the old image or showing the emoji. No snapshot uploads or remote fetching.
- Existing icon store/reference tests cover invalid image admission, missing and
  stale versions, response validation, cache limits, cancellation and replacement.
  The cache, version-keyed SwiftUI task and image-failure initials remain unchanged.
- Project icon rendering stays independent and unchanged.

Only Swift source parsing and `git diff --check` are permitted before the
orchestrator allocates the serial validation slot tracked by #316. Package tests
(`swift test --filter CompanionAgentFaceTests` then the full package suite), app
Debug/Release builds, hosted avatar tests and repository validation remain pending
that slot. Source parsing alone is not evidence of passing type checks or tests.
