# Phone workflow integration

Base: mobile integration `0fce51f`, plus Framebriar integrations `5a4414a` and `184e191` (SDK `d2a02f0`). Work is isolated on `codex/mobile-phone-workflow`; desktop companion changes are on `codex/annex-phone-workflow`. Nothing is merged or released.

## Features

- Nearby discovery browses `_clubhouse-annex._tcp.local.` only while the pairing sheet is open. Names/TXT are unauthenticated hints. Error/retry state explains permission/multicast failures. Manual entry accepts IPv4, hostname, bracketed IPv6, host:port or an exact HTTPS origin with an explicit port; no credentials, path, query or insecure HTTP.
- Pairing requires comparison of desktop identity and TLS fingerprints before PIN submission. Session-only is the default. No certificate is installed, no global trust is changed, and remembering access is explicit.
- A desktop-authorized sleeping durable exposes Wake agent. Sending a message can also resume it; the subsequent message uses the reconciled live session. Running terminal agents and historical sessions cannot falsely offer wake. Live controls remain capability-gated.
- Existing experimental `richChatContent` is respected. Authenticated mobile mTLS routes reuse desktop stored-image and agent-root file-preview policy. Only known non-disposed agents are addressable; revoked authorization is checked again after reads. Content is capped at 8 MiB binary and is not HTTP-cached.
- User-tapped stored-image previews support raster thumbnails, copy/share-preview, and sandboxed SVG image rendering (no JavaScript/external resources). Explicit code-span/Markdown file links support text/copy and platform-supported audio/video playback. AVFoundation is forbidden from following external references. Temporary playback files are protected and removed on close. Media never autoplays or loads arbitrary remote URLs; raster previews use the first frame and a maximum 2048-pixel edge.
- Framebriar Settings, UI model and optional shake-to-open shortcut are integrated. Shake opens an empty composer only for eligible enrolled users; it is debounced, suppressed while typing/presenting/inactive, and can be disabled. This build has no game ID and creates no feedback client. Enrollment, uploads, real credentials and screenshots remain opt-in, separately authorized actions; mocked flow tests exercise review/queue/delivery/disconnect.

## Physical phone prerequisites — not yet performed

1. Connect and unlock an iPhone running iOS 26+, pair it with Xcode as needed, and enable Developer Mode. Open `Annex/Annex.xcodeproj`, scheme `ClubhouseGo`.
2. Select the owner's authorized Apple account/team and establish device development signing/provisioning. The existing artifact is simulator-only; no IPA/TestFlight build is provided. Creating signing credentials/device security changes needs confirmation.
3. Run the matching desktop branch. Normal desktop Annex broadcasting behavior is unchanged. For an isolated manual-address phone test, source now supports `CLUBHOUSE_ANNEX_BIND_ADDRESS=<one existing local IPv4 address>`, `CLUBHOUSE_ANNEX_EPHEMERAL=1`, and a dedicated `CLUBHOUSE_USER_DATA` directory. Do not combine the bind flag with `CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`. This profile does not advertise. Starting a reachable listener requires action-time approval; no such listener has been started.
4. Discovery on a physical LAN needs an approved broadcasting desktop and iOS Local Network permission. Tailscale does not relay Bonjour by default; enter its reachable address/port manually. No VPN enrollment, firewall changes or broad listener exposure are implied.
5. Compare both fingerprints shown in desktop Annex settings, enter the PIN, leave Remember off for the isolated test, and end session pairing afterward.

## Boundaries and evidence

Simulator fixtures use production Annex/chat paths with an explicitly scripted CLI; provider streaming tests use fresh ephemeral Codex sessions and the existing login. These are distinct. Tests and screenshots are under task-13 `evidence/phone-*`; the private fixture harness is under task-13 `harness/phone-*`. No existing user agent or security worktree is used.

Physical multicast discovery, device signing/Keychain, real media codec coverage and physical LAN/Tailscale reachability remain device-validation gates. Remote web-image fetching, phone file/image upload to agents and desktop Reveal/Open actions are not exposed by this bounded content implementation. The preview reports unsupported formats/oversized content instead of claiming support.
