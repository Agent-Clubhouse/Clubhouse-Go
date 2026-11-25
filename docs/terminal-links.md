# Terminal links and the login round trip

A person runs `claude` → `/login` in a phone-spawned shell, opens the address, authorizes, and pastes the code back
into the same shell. Backgrounding Go disconnects it, and the desktop then ends every shell the phone spawned, so the
page must be opened without leaving the app.

- **Detection** (`CompanionTerminalScreen.logicalLines()`, `links()` in `CompanionTerminalLinks.swift`): the last cell of
  a row carries `wrapsToNextRow` when autowrap moved output onto the next row. Wrapped rows are joined into one logical
  line, so an address wrapped over several rows comes out exact; a hard newline always starts a new line. Scrollback and
  the screen are both searched (with the alternate screen, the main screen it hides comes first). Rows wrapped before a
  resize are not reflowed. Addresses end at whitespace, quotes, brackets and box-drawing characters; trailing sentence
  punctuation and unbalanced closing brackets are trimmed.
- **OSC 8 hyperlinks** are parsed: only complete `http(s)` targets are kept (up to 1024 distinct per screen; an OSC string
  over 2048 bytes is dropped, never trusted). A hyperlink is listed by its target, never by the text drawn over it. Other
  OSC sequences are unchanged.
- **UI**: a Links button appears in the terminal's toolbar when links exist (`terminal-links`). The sheet lists the newest
  links (`terminal-link-open-N`, `terminal-link-copy-N`). Open shows the address in `SFSafariViewController`, presented
  over full screen with UIKit so the terminal never leaves the hierarchy; the scene stays active, so the connection and the
  shell stay up. Copy puts the exact text on the pasteboard. Dismissing Safari restores the keyboard if it was up.
  `CompanionTerminalSession.viewDisappeared()` does not close the shell while a page is showing.
- **New shell**: after a dropped connection the notice says the desktop ended the previous shell and its programs. A shell
  is never replaced silently.
- Preview shell: the `links` command prints a synthetic Claude-like login prompt for the UI test.

Not handled: a program that wraps long text itself with hard newlines and no OSC 8 hyperlink (a hard newline is never
joined), and the Links action on a terminal-mode agent's PTY inside its chat (full-screen terminals only).
