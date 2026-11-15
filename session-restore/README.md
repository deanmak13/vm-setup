# session-restore

Brings every tmux window and its Claude Code / Codex conversation back after the dev box reboots.
User-level systemd units; no sudo to install.

## How it works

- `snapshot.sh` (timer, every 5 min): read-only walk of the tmux server (`list-panes`) plus each pane's
  process tree. For every pane it records session, window index/name, pane index, cwd, client
  (`claude|codex|shell`), the exact resume command, the agent session id, a confidence
  (`confident|inferred|guess`) and the Paperclip slug. Output: `~/.cache/pneuma-session-restore/snapshot-<UTC>.json`
  plus `latest.json` (newest 288 kept; an empty tmux server never overwrites `latest.json`).
  - Claude id: `CLAUDE_CODE_SESSION_ID` from a child process environ (confident); fallback newest
    `~/.claude/projects/<cwd>/*.jsonl` (guess).
  - Codex id: Paperclip link file (`~/.local/state/paperclip-link/<slug>`) matched by pane id and slug in the pane
    title (confident), then by elimination (inferred), then newest rollout for the cwd (guess).
- `restore.sh` (boot, 45 s after the user manager): for each session/window in snapshot order, creates the tmux
  session or window with the same name and index if it is missing (existing ones are skipped, so it is idempotent),
  `cd`s to the cwd (falls back to `~/Repos/pneuma` when the cwd is gone), and types the resume command
  (`claude --resume <id> <original flags>` / `codex resume <id> <original flags>`). `--dry-run` prints the plan only.
  Prints a table of what was restored. Manual run: `pneuma-session-restore [--dry-run] [--snapshot FILE]`.
- The tmux server started by the restore unit is launched through `systemd-run --user --scope` so it outlives the
  oneshot service.

## Install

```bash
bash session-restore/install.sh [--dry-run]
```

Copies the scripts to `~/.local/bin/pneuma-session-{snapshot,restore}`, installs the units into
`~/.config/systemd/user/`, enables the snapshot timer and the restore service (restore runs at next boot only).

### Linger

User units only start at boot if linger is on. Check: `loginctl show-user deanmak13 -p Linger`. It is `yes` on the
dev box today. If it is ever off: `sudo loginctl enable-linger deanmak13` (needs sudo; the installer only warns).

## What is restored

- The tmux layout: session name, window indexes and names, pane splits, working directories.
- Each Claude Code / Codex conversation, via resume. A session that was mid-tool-call resumes at its last saved message.
- Tools listed in `PNEUMA_RESTORE_TOOLS` (default `k9s`) are relaunched fresh.

## What is not restored

- In-flight subagents and background commands die at reboot; nothing re-runs them.
- Shell scrollback and shell history state, nested `sudo`/`su` shells (they come back as a plain shell).
- `/tmp` is wiped at reboot, so worktrees there are gone: a window whose cwd no longer exists restarts in
  `~/Repos/pneuma` (the restore says so). Keep session worktrees under `~/.cache`.
- Paperclip links record the old process pid; sessions may need a re-link via the paperclip-identity skill.

## Reboot schedule

The weekly reboot stays at Sunday 04:00 (Dean's decision 2026-11-15); nightly tests start 04:30, after the restore
service has finished.

## Environment overrides

`PNEUMA_TMUX_SOCKET`, `PNEUMA_SESSION_RESTORE_DIR`, `PNEUMA_RESTORE_FALLBACK_CWD`, `PNEUMA_RESTORE_TOOLS`,
`PNEUMA_RESTORE_SERVER_WRAP`, `PAPERCLIP_LINK_DIR`.
