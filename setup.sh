#!/usr/bin/env bash
# setup.sh — First-run bootstrap for a fresh VM instance.
# Installs AWS CLI, configures credentials, then pulls the real
# bootstrap script from S3 and runs it.
#
# Usage:
#   bash setup.sh                          # Interactive (prompts for credentials)
#   bash setup.sh --env                    # Use existing AWS_* env vars
#
# What this does NOT contain: credentials, dotfiles, project configs.
# All of that lives in S3 and gets pulled by bootstrap.sh.

set -euo pipefail

S3_BUCKET="s3://pneuma-dev-state"
BOOTSTRAP_PATH="scripts/bootstrap.sh"
LOCAL_BIN="$HOME/.local/bin"

export PATH="$LOCAL_BIN:$PATH"

log() { echo "[vm-setup] $*"; }
err() { echo "[vm-setup] ERROR: $*" >&2; exit 1; }

# --- Install AWS CLI if missing ---
if ! command -v aws &>/dev/null; then
    log "Installing AWS CLI..."
    mkdir -p "$LOCAL_BIN"
    apt-get update -qq && apt-get install -y -qq unzip curl > /dev/null 2>&1 || true
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp/aws-cli-install
    /tmp/aws-cli-install/aws/install --install-dir "$HOME/.local/aws-cli" --bin-dir "$LOCAL_BIN" --update
    rm -rf /tmp/awscliv2.zip /tmp/aws-cli-install
    log "AWS CLI installed: $(aws --version)"
else
    log "AWS CLI already installed: $(aws --version)"
fi

# --- Configure AWS credentials ---
if [[ "${1:-}" == "--env" ]]; then
    log "Using AWS credentials from environment variables..."
    : "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID env var}"
    : "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY env var}"
    : "${AWS_DEFAULT_REGION:?Set AWS_DEFAULT_REGION env var}"
else
    if ! aws sts get-caller-identity &>/dev/null; then
        log "AWS credentials needed. Running 'aws configure'..."
        aws configure
    else
        log "AWS credentials already configured."
    fi
fi

# --- Verify credentials work ---
if ! aws sts get-caller-identity &>/dev/null; then
    err "AWS credentials invalid. Check your access key and secret."
fi
log "Authenticated as: $(aws sts get-caller-identity --query Arn --output text)"

# --- Test bucket access ---
if ! aws s3 ls "$S3_BUCKET/" &>/dev/null; then
    err "Cannot access $S3_BUCKET. Check that the bucket exists and your IAM policy allows access."
fi

# --- Pull bootstrap.sh from S3 and run it ---
log "Pulling bootstrap.sh from S3..."
if aws s3 cp "$S3_BUCKET/$BOOTSTRAP_PATH" "$HOME/bootstrap.sh"; then
    chmod +x "$HOME/bootstrap.sh"
    log "Running bootstrap.sh..."
    bash "$HOME/bootstrap.sh"
else
    err "bootstrap.sh not found in S3 at $S3_BUCKET/$BOOTSTRAP_PATH. Run save-state.sh on an existing instance first."
fi
