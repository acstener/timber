# Privacy

Timber is built to keep what's on your disk on your disk.

## What stays on your Mac — always

- Scanning, sizes, the deadwood rules, git checks and the chop log all run locally.
- Timber never uploads files, file contents, file names or paths.
- There's no account and no cloud sync.

## Anonymous usage stats (on by default, easy to turn off)

To learn which features are useful, the app sends a handful of anonymous events to PostHog:

| Event | What's included |
|---|---|
| `app_opened` | app version, macOS version |
| `survey_started` | home / folder / whole disk |
| `survey_completed` | size range (e.g. "50–200GB"), thousands of files, seconds taken, deadwood count and size range |
| `tree_chopped` | kind (folder, video, installer…), size range, deadwood safety level, ranger mark, whether it was a git worktree |
| `deadwood_cleared`, `chop_undone`, `ranger_used`, `replay_used`, `trash_emptied`, `chop_failed` | counts and size ranges only |

Every event is tied to a random ID created on install — not to you, your Mac or an account. Events don't create person profiles, GeoIP lookup is disabled, and the project discards IP addresses. **Never** sent: file names, folder names, paths, exact sizes, or anything about what your files contain.

Turn it off any time: **Timber → Settings → General → Share anonymous usage stats**. The code is in [`Sources/App/Telemetry.swift`](Sources/App/Telemetry.swift). Debug builds never send anything.

## The Ranger (optional)

If you add your own TypeSafe API key, the Ranger sends the **names, sizes, dates and git status** of the items you ask it about to TypeSafe's Jev model to get a "chop / look first / keep" mark. Never file contents. No key, no requests.

## The Claude MCP server

`timber-mcp` runs entirely on your Mac and never phones home. Claude (the client you connect it to) sees whatever the tools return — folder names and sizes — just like any other local MCP tool. The Ranger tool only works if you give the server a TypeSafe key.

## The website

Timber's website uses PostHog for anonymous page views and download clicks, with no cookies, no local storage and no session recording.
