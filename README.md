# Dev Island

**English** · [Türkçe](README.tr.md)

A native macOS menu bar app that keeps you informed while Claude Code works. Follow multiple sessions from a notch-aware island, get notified when a session needs attention, and return to the terminal it belongs to.

**Current version: 0.4.1 — local alpha.** Signed distribution and end-to-end automatic updates still require release configuration and device acceptance. See [validation](docs/VALIDATION.md) for completed checks and remaining work.

## Features

- **Multiple sessions:** Claude session names, custom labels and persistent waiting states across projects and terminals.
- **Attention at a glance:** questions, plan approvals, permission requests, response completion, failures and disconnected sessions.
- **Movable island:** pin to the top center, save a custom position, or open the docked panel and drag **Move**. Clicking Move detaches the island below the menu bar.
- **Animated companions:** Clawd, Cat and Robot share session states across the island and a draggable desktop mascot. Use either surface or both.
- **Personal appearance:** system/light/dark/black themes (black blends the island with the notch), customizable accent and per-character colors, separate reset controls, and Liquid Glass, frosted or opaque surfaces. Liquid Glass falls back to frosted glass on macOS 14/15.
- **Configurable alerts:** event-specific notifications and sounds, custom audio volume, quiet hours, snooze and session muting.
- **Native accessibility:** Reduce Motion, Reduce Transparency, keyboard access and a customizable session shortcut.
- **English and Turkish interfaces.**

## Requirements

- Apple Silicon Mac running **macOS 14 or later**.
- Claude Code installed locally for session tracking.
- To build: **Xcode 26 or later** with its command-line tools selected, and Python 3. The source uses the macOS 26 SDK for Liquid Glass while targeting macOS 14+.
- SwiftPM downloads the pinned **Sparkle 2.9.6** dependency during the build. Node.js is needed for connector tests.

## Build and connect

From the repository root:

```bash
bash scripts/build-app.sh
open "dist/Dev Island.app"
```

The script creates `dist/Dev Island.app` and a versioned ZIP, currently `dist/Dev-Island-0.4.1-arm64.zip`. Local builds are ad-hoc signed. Move the app to Applications before setting up the integration. When replacing an older copy, **quit the running Dev Island first**, then launch the new copy.

1. In Settings, open **Claude connection** and review the hooks before installing them. Existing Claude settings and other hooks are preserved; installation backs up `settings.json`.
2. Restart existing Claude sessions after the initial hook installation, then send a prompt to verify tracking.
3. Grant notification permission in **Alerts & sound** if you want system notifications. Launch at login is optional and off by default.
4. For exact VS Code routing, choose **Install / update VS Code connection**. The VSIX is bundled. If a window does not connect, reload it when convenient; existing terminals are not recreated.

## Everyday use

Open sessions from the menu bar or the default **⇧⌘D** shortcut. Hover opens the island without activating the app; clicking keeps the list open until you close it. Escape closes the panel or cancels a drag.

When pinned, open the panel and drag the **64×32 pt Move handle** below the menu bar. Clicking it detaches the island into the usable screen area. The floating header's pin button returns it to the top center. Positions are saved, and the panel can open upward near the bottom of a screen.

Dismissing or muting an alert does not resolve a waiting question; Claude must emit a continuation event. A completed response means Claude's turn ended, not that the entire project succeeded. The desktop mascot does not generate duplicate alerts.

## Return to your terminal

| Application | Current behavior |
| --- | --- |
| VS Code | Selects the matching local window and terminal through the bundled connector, using process identity rather than name or project-path guesses. |
| Apple Terminal | Selects the matching tab using its TTY with Automation permission; otherwise brings Terminal forward. |
| Cursor / Warp | Brings the source application forward; exact terminal selection is not supported yet. |

Missing or unverifiable VS Code targets report an error rather than opening a replacement terminal. SSH, remote/dev-container terminals and tmux pane selection are outside the current scope. See [connector setup](extensions/vscode/README.md) and [routing details](docs/V036_VSCODE_ROUTING.md).

## Sound and Focus

The balanced profile sounds for questions, approvals, permissions and failures; response completion is silent by default. System notifications and their sounds follow macOS delivery and Focus rules. Custom audio has its own volume control; custom audio and the island do not automatically follow Focus. Quiet mode, quiet hours and session muting control alerts without removing waiting sessions.

## Privacy and local data

Tracking runs locally through Claude Code hooks and a small bridge. It requires no account or server, and adds no telemetry.

- The disk queue and SwiftData history store session metadata, not raw hook payloads, prompts, commands, plans or full transcripts. Session naming reads local metadata without modifying Claude's files.
- Question previews stay in memory. System notifications use generic status text.
- Data lives in `~/Library/Application Support/DevIsland/`; preferences use UserDefaults. History retention defaults to seven days, while active and unresolved sessions are preserved.
- `CLAUDE_CONFIG_DIR` and the settings directory field support custom Claude configurations.
- Tracking does not require Screen Recording, Accessibility or Full Disk Access. Apple Terminal tab selection may request Automation permission.

Remove the integration from **Claude connection → Remove connection**. Other hooks remain intact. The bridge stays in place so older running sessions with cached hook commands can exit safely.

## Updates and releases

Sparkle supports hourly checks, manual checks and optional beta releases in **Settings → Updates**. Installation requires user action. Official builds use GitHub Releases for packages and GitHub Pages for the feed; session content is not sent to these services.

**Remote updates are disabled in local ad-hoc builds.** Developer ID Application signing, notarization, repository secrets and Pages setup must be completed before official updates can be published. The first updater-enabled release needs a manual installation; later official releases can update in place.

[`Resources/version.json`](Resources/version.json) is the version/build source of truth. See [release setup](docs/UPDATES.md) for signing, stable/beta tags and the publishing workflow.

## Development and verification

```bash
bash scripts/swift.sh test
node --test extensions/vscode/test/router.test.js
bash scripts/build-app.sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/smoke-bridge.py
python3 scripts/smoke-session-names.py
"dist/Dev Island.app/Contents/MacOS/DevIsland" --verify-storage
```

Build before running release-script tests so Sparkle's signing tools are available. The latest recorded validation reports **131 passing Swift tests, one skipped physical-screen test, 11 connector tests and five release tests**. Physical mouse/trackpad, Spaces, multi-display and signed-update acceptance remain documented separately; automated tests and rendered previews do not replace those checks.

For sample sessions with a separate data directory, quit the running app first:

```bash
open -n "dist/Dev Island.app" --args --demo --data-dir /tmp/dev-island-demo --show-settings
```

Demo mode does not install hooks or request notification permission. To render layout previews:

```bash
.build/arm64-apple-macosx/release/DevIsland --demo --data-dir /tmp/dev-island-render --render-preview previews
```

## Documentation

- [Product and architecture](docs/PLAN.md)
- [Roadmap](docs/ROADMAP.md)
- [Validation and acceptance gaps](docs/VALIDATION.md)
- [Pinned-island movement](docs/V041_PINNED_DRAG.md)
- [Session names](docs/V035_SESSION_NAMES.md)
- [Release and update setup](docs/UPDATES.md)
- [Asset notices](docs/ASSET_NOTICES.md) · [Sparkle license](Resources/ThirdParty/Sparkle-LICENSE.txt)

Some technical documents are currently in Turkish.
