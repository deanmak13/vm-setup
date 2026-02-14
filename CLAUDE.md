# vm-setup

Generic VM bootstrap script. No project-specific content — just the ignition key
that pulls the real environment from AWS S3.

## What this repo does

`setup.sh` is the only thing that matters here. It:
1. Installs the AWS CLI (if missing)
2. Prompts for AWS credentials (or reads from env vars with `--env`)
3. Pulls `bootstrap.sh` from a private S3 bucket
4. Runs `bootstrap.sh`, which restores dotfiles, Claude Code state, repos, etc.

## Usage on a fresh VM

```bash
git clone https://github.com/deanmak13/vm-setup.git ~/vm-setup
bash ~/vm-setup/setup.sh
```

Or with env vars (no interactive prompt):
```bash
AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=xxx AWS_DEFAULT_REGION=us-east-1 bash ~/vm-setup/setup.sh --env
```

## What lives where

| Location | Contents |
|----------|----------|
| **This repo (GitHub)** | `setup.sh` — generic, no secrets, no project config |
| **S3 bucket** | bootstrap.sh, save-state.sh, dotfiles, Claude Code state, AWS config, gh CLI auth |
| **Project repos (GitHub)** | Source code, CLAUDE.md files |

## Rules
- Never commit credentials, tokens, or secrets to this repo
- Keep setup.sh generic — no project-specific logic belongs here
- All sensitive/personal state goes to S3 via save-state.sh
