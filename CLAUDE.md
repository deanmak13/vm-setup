# vm-setup

Generic VM bootstrap for restoring a dev environment from AWS S3.

## How to use this repo

When the user asks to "set up my environment", "run setup", "bootstrap", or anything similar:

1. Run `bash ~/vm-setup/setup.sh`
2. The script will prompt the user for AWS credentials interactively (unless AWS env vars are already set)
3. It handles everything else automatically: installs AWS CLI, pulls bootstrap.sh from S3, runs it

That's it. Do not modify setup.sh or add project-specific logic here.

If setup.sh is not found at `~/vm-setup/setup.sh`, clone it first:
```bash
git clone https://github.com/deanmak13/vm-setup.git ~/vm-setup
```

## What the full flow does

```
setup.sh (this repo, from GitHub)
  → Installs AWS CLI
  → Prompts for AWS credentials
  → Pulls bootstrap.sh from s3://pneuma-dev-state/scripts/
  → Runs bootstrap.sh, which:
      → Restores ~/.aws/ (AWS config)
      → Restores dotfiles (.bashrc, .gitconfig, etc.)
      → Restores ~/.claude/ (Claude Code memories, settings, plugins)
      → Restores ~/.claude.json (Claude Code auth and project state)
      → Restores ~/.config/gh/ (GitHub CLI auth)
      → Clones project repos from GitHub
      → Restores bootstrap.sh and save-state.sh to ~/
```

## Before shutting down a VM

Remind the user to run:
```bash
bash ~/save-state.sh
```
This syncs all state back to S3. If the user says "shutting down", "saving state",
or "tearing down", run that command.

## What lives where

| Location | Contents |
|----------|----------|
| **This repo (GitHub)** | `setup.sh` only — generic, no secrets, no project config |
| **S3 (`pneuma-dev-state`)** | bootstrap.sh, save-state.sh, dotfiles, Claude Code state, AWS config, gh auth |
| **Project repos (GitHub)** | Source code, CLAUDE.md files |

## Rules

- Never commit credentials, tokens, or secrets to this repo
- Keep setup.sh generic — no project-specific logic belongs here
- All sensitive/personal state goes to S3 via save-state.sh
