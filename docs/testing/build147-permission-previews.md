# Go 147 bounded permission preview audit

Frozen source: `6c32b12`. The compatibility test uses real AnnexTransport byte/envelope
and command-receipt decoding, CompanionLiveService, and observable CompanionStore.
HTTP and WebSocket bytes are scripted locally. No archived app installation is needed.
Card text visibility below is verified against the frozen CompanionApprovalCard body;
this is a model and source audit, not a screenshot claim.

Fifteen cases passed: five payload shapes each through `/chat` pendingPermissions,
live `chat:event`, and replayed `chat:event` (`replayed:true`), with inner event type
`permission_request`. The literal outer `permission:request` event is ignored by 147.
The desktop must preserve its existing rich-chat translation.

| Input or action | Observable result on 147 |
|---|---|
| Write with title `Write large.txt`, description `Write file`, `rawInput.file_path` and head/tail `rawInput.content` | Heading and summary are those strings. Collapsed Review details shows basename plus first 400 Swift Characters of content. It does not display the full path. |
| Unknown `truncated:true`, `totalBytes:20000000`, including inside rawInput | Ignored. No automatic incomplete indicator or approval restriction. |
| `toolInput` alone | No detail. The card does not read this field directly. |
| `content:[{type:text,text:...}]` | Supplied text appears in collapsed Review details, taking precedence over rawInput. No 400-character shortening on this route. |
| Explicit warning at start of description | Immediately visible summary outside the disclosure; use this to warn legacy users. |
| Incomplete marker after 450 characters of rawInput.content | Marker is lost. Head/tail and warning must fit the visible preview; do not rely on tail metadata. |
| Allow once: HTTP 409 valid command receipt, status rejected, error code incomplete_representation, message sentence | Card remains pending, actions re-enabled, no resync or automatic retry. Error banner displays the exact desktop sentence. A second user tap sends a new command and can be refused again. |
| Deny after refusal, completed receipt | Card becomes Denied, error banner clears. |

The sentence tested is: “This input is incomplete. Review the full request on desktop
before approving.” This must be a valid versioned command receipt with the matching
commandId and epoch, not a bare HTTP error JSON. A failed receipt means uncertain
outcome instead; use rejected for a refusal before execution.

The 147 preview limits Characters, not UTF-8 bytes. The server must bound true UTF-8
bytes independently, and enforce rejection of approving an incomplete representation.
An explicit description warning survives the default collapsed details state. Unknown
metadata by itself cannot protect users of this legacy client.

Run `swift test --package-path build/build147 --filter
Build147TransportAuditTests.permissionPreviewSnapshotLiveReplayAndRefusedApproval`
after the frozen-source setup in [the overflow audit](build147-overflow-options.md).
