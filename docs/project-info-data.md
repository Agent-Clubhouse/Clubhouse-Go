# Project info data availability (#443)

All requested fields already exist in the pinned desktop contract. No desktop issue or new wire field is needed.

| Detail | Existing source | Handling |
|---|---|---|
| Path per project copy | `projects[].path` in snapshot and REST project catalog | Preserve the received optional root in CompanionProject; never infer it from an agent worktree. |
| Linked desktops | Existing replicated `projectLinks` plus the paired host/project catalog | Show each member with its machine label; keep distinct project roots even when multiple copies share a desktop. |
| Default access | Existing mobile create-options `defaults.access` and access-level labels | Show only a recognized, received value. |
| MCP defaults | Existing mobile create-options `mcp.defaults` and `mcp.catalog` | Preserve absent/malformed versus explicitly empty defaults. Show received unknown catalog IDs as themselves rather than dropping a reported default. |

Canonical evidence is in `Tests/Fixtures/AnnexContract/snapshot.json`, `rest-catalog.json`, and `create-options.json`. Previously the app discarded project roots and collapsed absent MCP defaults to an empty array. The new internal path/presence fields retain that data; the protocol is unchanged.

Opening the info sheet reads the existing create-options endpoint once per visible, connected supported member. Offline and unsupported members do not read. Reads belong to the member's endpoint/control epoch and are cancelled when that context changes. The sheet clears obsolete values before reading a new context; late cancelled replies cannot update its presentation. Retry performs the same read. No command, create, settings update or local preference write is sent.

Older desktops may omit individual fields or offer no create-options capability. Omitted values stay hidden; an explicit empty MCP selection alone displays “None”. The available machine names and received paths remain readable when defaults cannot be read. The footer directs editing to the desktop.

Validation is pending. Hosted checks render the real sheet in light, dark, two non-default desktop themes and accessibility AX3, and count its connected/offline reads. UI checks cover single and linked project entry points and the absence of editors. No physical-device or live-desktop validation is claimed.
