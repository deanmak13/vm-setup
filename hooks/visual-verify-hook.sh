#!/usr/bin/env bash
# Visual verification hook for Claude Code.
# Triggered by PostToolUse on Edit|Write.
#
# 1. Checks if the modified file is a UI file (.svelte, .css) in portal paths
# 2. If yes: starts preview server (if not running), takes screenshots, tells Claude to verify
# 3. If no: exits silently (non-UI file, no action needed)
#
# Outputs JSON with hookSpecificOutput.additionalContext to instruct Claude
# to read the screenshots and verify them.

set -euo pipefail

# Read the hook input from stdin
INPUT=$(cat)

# Extract the file path from the tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // ""')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only trigger for UI files in portal paths
case "$FILE_PATH" in
  */pneuma-portal/apps/admin/src/*.svelte | \
  */pneuma-portal/apps/admin/src/*.css | \
  */pneuma-portal/packages/ui/src/*.svelte | \
  */pneuma-portal/packages/ui/src/*.css)
    # This is a UI file — proceed with visual verification
    ;;
  *)
    # Not a UI file — exit silently
    exit 0
    ;;
esac

# Debounce: skip if we verified less than 30 seconds ago
LOCK_FILE="/tmp/pneuma-visual-check/.last-verify"
if [ -f "$LOCK_FILE" ]; then
  LAST=$(cat "$LOCK_FILE")
  NOW=$(date +%s)
  DIFF=$((NOW - LAST))
  if [ "$DIFF" -lt 30 ]; then
    exit 0
  fi
fi

# Mark verification time
mkdir -p /tmp/pneuma-visual-check
date +%s > "$LOCK_FILE"

PORTAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_PORT=4173
PREVIEW_PID_FILE="/tmp/pneuma-visual-check/.preview-pid"

# Check if preview server is running
if ! curl -s --max-time 2 "http://localhost:$PREVIEW_PORT" > /dev/null 2>&1; then
  # Build and start preview server in background
  cd "$PORTAL_DIR/apps/admin"

  # Build if no build output exists or source is newer
  if [ ! -d ".svelte-kit/output" ]; then
    npx vite build > /dev/null 2>&1
  fi

  # Start preview server with auth bypass
  TEST_BYPASS_AUTH='{"user":{"id":"visual-test","email":"visual@test.com"},"session":{"access_token":"vt"},"portalUser":{"id":"vt1","auth_id":"visual-test","email":"visual@test.com","display_name":"Visual Tester","role_scope":"platform","tenant_id":null},"permissions":["tenants.read","platform_users.read","models.read","system_health.read"]}' \
  VISUAL_TEST_MODE=true \
  NODE_ENV=test \
  npx vite preview --port "$PREVIEW_PORT" > /dev/null 2>&1 &

  echo $! > "$PREVIEW_PID_FILE"

  # Wait for server to be ready (max 15s)
  for i in $(seq 1 30); do
    if curl -s --max-time 1 "http://localhost:$PREVIEW_PORT" > /dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
fi

# Take screenshots via Docker (system Chromium deps not available on host)
# --network host lets the container reach localhost:$PREVIEW_PORT on the host
cd "$PORTAL_DIR"
ROUTES_DIR="$PORTAL_DIR/apps/admin/src/routes"
SCREENSHOT_OUTPUT=$(docker run --rm \
  --network host \
  -v /tmp/pneuma-visual-check:/tmp/pneuma-visual-check \
  -v "$PORTAL_DIR/scripts/visual-check.mjs:/app/visual-check.mjs:ro" \
  -v "$ROUTES_DIR:/app/routes:ro" \
  mcr.microsoft.com/playwright:v1.52.0-noble \
  bash -c "npm install --no-save playwright-core@1.52.0 > /dev/null 2>&1 && node /app/visual-check.mjs http://localhost:$PREVIEW_PORT --routes-dir=/app/routes" 2>&1) || true

# Count successful screenshots
SCREENSHOT_COUNT=$(echo "$SCREENSHOT_OUTPUT" | grep -c "\[ok\]" || true)
SCREENSHOT_COUNT=${SCREENSHOT_COUNT:-0}
FAIL_COUNT=$(echo "$SCREENSHOT_OUTPUT" | grep -c "\[FAIL\]" || true)
FAIL_COUNT=${FAIL_COUNT:-0}

# Build dynamic file list from what was actually captured
SCREENSHOT_FILES=$(find /tmp/pneuma-visual-check -name '*.png' -newer "$LOCK_FILE" 2>/dev/null | sort)
FILE_LIST=""
for f in $SCREENSHOT_FILES; do
  FILE_LIST="${FILE_LIST}\n- ${f}"
done

if [ "$SCREENSHOT_COUNT" -gt 0 ]; then
  # Escape the file list for JSON
  ESCAPED_FILES=$(echo -e "$FILE_LIST" | sed 's/"/\\"/g' | tr '\n' ' ')

  # Output JSON telling Claude to verify the screenshots
  cat <<ENDJSON
{
  "suppressOutput": true,
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "VISUAL VERIFICATION REQUIRED: You modified a UI file ($FILE_PATH). $SCREENSHOT_COUNT screenshots captured ($FAIL_COUNT failed) to /tmp/pneuma-visual-check/.\n\nYou MUST now read EVERY screenshot using the Read tool and visually verify each one against this checklist:\n\n1. LAYOUT: No text overlap, clipping, or elements bleeding outside containers\n2. SIZING: Logo/brand mark renders at correct size (sm=32px in sidebar, not 200px)\n3. SCROLLING: Single scrollbar per page — no visible nested scrollbars\n4. SPACING: Cards, buttons, inputs properly spaced — no cramped or floating elements\n5. THEME: Dark mode correct (dark bg #0a0a0a, teal #00ced1 accents), no white flashes\n6. TYPOGRAPHY: Headings bold, body text readable, tabular-nums on metrics, no font fallbacks\n7. RESPONSIVENESS: Mobile views stack correctly, touch targets ≥44px, no horizontal overflow\n8. COMPONENTS: Badges render with correct colors, icons visible, empty states show guidance\n9. INTERACTIVE: Hover states visible on cards (card-hover class), active nav items highlighted\n10. ANIMATIONS: Breathing logo visible in sidebar, stagger positions visible on dashboard cards\n11. NAVIGATION: Sidebar items correct and complete, active route highlighted with primary bar\n12. COMPLETENESS: No blank pages, no error screens, no missing content sections\n\nScreenshot files to read:${ESCAPED_FILES}\n\nPROCESS: Read screenshots in batches of 4-6 (parallel Read calls). Report findings per-screenshot. If ANY issue is found, fix it immediately — the hook will re-trigger on the next edit to re-verify.\n\nIf all screenshots pass: report 'VISUAL VERIFICATION PASSED: X/Y screenshots verified, no issues found.'"
  }
}
ENDJSON
else
  # Screenshots failed — tell Claude but don't block
  ESCAPED_OUTPUT=$(echo "$SCREENSHOT_OUTPUT" | head -20 | sed 's/"/\\"/g' | tr '\n' ' ')
  cat <<ENDJSON
{
  "suppressOutput": true,
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "VISUAL VERIFICATION WARNING: Screenshot capture failed for $FILE_PATH ($FAIL_COUNT failures). Output: $ESCAPED_OUTPUT. The preview server may not be running or the build may have failed. Try: 1) Build: cd pneuma-portal/apps/admin && npx vite build  2) Start preview: TEST_BYPASS_AUTH=... VISUAL_TEST_MODE=true npx vite preview --port 4173  3) Re-edit the file to re-trigger this hook."
  }
}
ENDJSON
fi
