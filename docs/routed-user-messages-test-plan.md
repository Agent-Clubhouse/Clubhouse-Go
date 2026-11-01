# Routed user messages test plan

- Project hand-built `RoutedMessagePart` data from desktop `events.ts`: single sender, ordered burst, Clubhouse, unknown sender, unknown fields, and malformed neighbours. Move these inputs to contract fixtures when desktop #2617 lands.
- Prefer structured sender/body even when content or the body contains routing tags. Keep content whole for Copy. Match desktop reply-marker display and source/steer captions.
- Pin existing MCP `[TASK:] [FROM:]` parsing, untagged fallback, and other sources when routed is absent, empty or unusable.
- Exercise live chat events, chat snapshots, and paginated saved history through the shared projector, including duplicate events.
- Preview dispatcher smoke: four distinct accessible messages with sender/body; no delivery envelope; Copy available; screenshot retained.
- Run package tests, vendored SDK tests, coverage ratchet, simulator Debug/Release builds, app tests, dispatcher and preview UI smoke tests, and the long-reply scrolling regression test. Check repository lint configuration and whitespace.

The [preview burst screenshot](screenshots/routed-burst.png) shows its Dispatcher and Reviewer messages. The smoke test verifies all four parts, including Clubhouse and an unnamed sender, and pastes Copy message into the composer to compare the whole raw delivery.
