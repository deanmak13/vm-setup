#!/usr/bin/env bash
# Completeness verification hook for Claude Code.
# Runs as a Stop hook — blocks agent from finishing if orphaned artifacts exist.
#
# Checks:
# 1. Every .svelte component in lib/components/ui/ is imported somewhere
# 2. Every @layer components class in app.css is used in a template
# 3. Every custom component (non-shadcn) in lib/components/ has at least one consumer
# 4. Every npm dependency is imported somewhere in src/
#
# Returns blocking JSON if orphans found, exit 0 if clean.

set -euo pipefail

INPUT=$(cat)

# Anti-loop: if we're already in forced-continuation, let the agent stop
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

PORTAL_DIR="/home/deanmak13/Repos/pneuma/pneuma-portal"
SRC_DIR="$PORTAL_DIR/apps/admin/src"
ISSUES=""

# ── Check 1: Custom UI components that are never imported ──────────
# Only check non-directory .svelte files (not shadcn sub-component dirs)
for f in "$SRC_DIR/lib/components/ui/"*.svelte; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f" .svelte)
  # Skip index files
  [ "$BASENAME" = "index" ] && continue

  # Convert kebab-case filename to possible import patterns
  IMPORT_COUNT=$(grep -rl "$BASENAME" \
    "$SRC_DIR/routes/" \
    "$SRC_DIR/lib/components/layout/" \
    "$SRC_DIR/lib/components/pipeline/" \
    "$SRC_DIR/lib/components/nous/" \
    "$SRC_DIR/lib/components/automations/" \
    "$SRC_DIR/lib/components/command-palette/" \
    "$SRC_DIR/lib/components/graph/" \
    --include="*.svelte" --include="*.ts" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  IMPORT_COUNT=$(echo "$IMPORT_COUNT" | tr -d '[:space:]')
  if [ "${IMPORT_COUNT:-0}" -eq 0 ]; then
    ISSUES="${ISSUES}ORPHANED COMPONENT: $BASENAME.svelte — created but never imported anywhere\\n"
  fi
done

# ── Check 2: CSS @layer classes never used in templates ────────────
APP_CSS="$SRC_DIR/app.css"
if [ -f "$APP_CSS" ]; then
  # Extract class names from @layer components blocks
  LAYER_CLASSES=$(grep -oP '\.\K[a-z][a-z0-9-]+(?=\s*\{)' "$APP_CSS" 2>/dev/null | sort -u || true)
  for CLASS in $LAYER_CLASSES; do
    # Skip pseudo-classes and variant suffixes
    [[ "$CLASS" == *":"* ]] && continue

    USAGE_COUNT=$(grep -rl "\"$CLASS\"\|'$CLASS'\|class=\"[^\"]*$CLASS\|class=\"$CLASS\|class:$CLASS" \
      "$SRC_DIR/routes/" "$SRC_DIR/lib/components/" \
      --include="*.svelte" 2>/dev/null | wc -l | tr -d ' ')

    USAGE_COUNT=$(echo "$USAGE_COUNT" | tr -d '[:space:]')
    if [ "${USAGE_COUNT:-0}" -eq 0 ]; then
      ISSUES="${ISSUES}ORPHANED CSS CLASS: .$CLASS — defined in app.css but never used in any template\\n"
    fi
  done
fi

# ── Check 3: Brand tokens never referenced ─────────────────────────
BRAND_TOKENS="$PORTAL_DIR/packages/ui/src/theme/brand-tokens.css"
if [ -f "$BRAND_TOKENS" ]; then
  TOKENS=$(grep -oP '--[a-z][a-z0-9-]+' "$BRAND_TOKENS" 2>/dev/null | sort -u || true)
  for TOKEN in $TOKENS; do
    # Check if used in any CSS or Svelte file (excluding brand-tokens.css itself)
    USAGE=$(grep -rl "$TOKEN" "$SRC_DIR/" "$PORTAL_DIR/packages/ui/src/theme/tokens.css" \
      --include="*.css" --include="*.svelte" --include="*.ts" 2>/dev/null | \
      grep -v "brand-tokens.css" | wc -l | tr -d ' ')

    USAGE=$(echo "$USAGE" | tr -d '[:space:]')
    if [ "${USAGE:-0}" -eq 0 ]; then
      ISSUES="${ISSUES}ORPHANED TOKEN: $TOKEN — defined in brand-tokens.css but never consumed\\n"
    fi
  done
fi

# ── Report ─────────────────────────────────────────────────────────
if [ -n "$ISSUES" ]; then
  # Escape for JSON
  ESCAPED=$(echo -e "$ISSUES" | sed 's/"/\\"/g' | tr '\n' ' ')
  cat <<ENDJSON
{
  "decision": "block",
  "reason": "INCOMPLETE WORK DETECTED. The following artifacts were created but never wired into production code:\\n\\n${ESCAPED}\\n\\nFix: Import and apply each orphaned artifact in the relevant files. Creating something without using it is dead code — the task is not done until it's visible to users."
}
ENDJSON
else
  # All clean — allow stop
  exit 0
fi
