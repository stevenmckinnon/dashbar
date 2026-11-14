# Security

## Reporting a vulnerability

Please report it privately through GitHub: [Report a vulnerability](https://github.com/stevenmckinnon/dashbar/security/advisories/new)
(the repository's Security tab). Please don't open a public issue for it. Say what you found, which version, and how to
reproduce it. This is a one-person open-source project, so replies are best-effort, but reports are read.

## What Dashbar touches

- Reads Claude Code's session files under `~/.claude` and Codex's under `~/.codex`, and lists listening ports and process details with libproc.
- Measures folders for clean-up, and moves rebuildable ones (`node_modules`, build output and similar) to the Trash only after you confirm. It never deletes permanently.
- Keeps its own settings and scan progress in `~/Library/Application Support/Dashbar/` and a shared plan reading (percentages, reset times and plan name only) in `~/Library/Caches/Dashbar/`.
- If you turn on Claude plan limits (off by default), it reads Claude Code's sign-in from the Keychain with `/usr/bin/security`, keeps it in memory, and makes one read-only request to `api.anthropic.com`. It never refreshes, stores or logs the sign-in.
- Network: only Sparkle update checks to GitHub and that opt-in request. No analytics, no accounts.

Releases are signed with a Developer ID, notarised by Apple, and updates are verified with a Sparkle signature.
