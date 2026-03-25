#!/usr/bin/env bash
# bin/statusline.sh — Autotune status line for Claude Code
# Reads session JSON from stdin + autotune state files to display progress.
# Configure in settings.json:
#   "statusLine": { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh" }

set -euo pipefail

# Read Claude Code session data from stdin
SESSION_JSON=$(cat)

# Extract session info
COST=$(echo "$SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('cost',{}).get('total_cost_usd',0):.2f}\")" 2>/dev/null || echo "0.00")
DURATION_MS=$(echo "$SESSION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cost',{}).get('total_duration_ms',0))" 2>/dev/null || echo "0")
CONTEXT_PCT=$(echo "$SESSION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('context_window',{}).get('used_percentage',0))" 2>/dev/null || echo "0")

# Format duration
DURATION_MIN=$(python3 -c "print(f'{$DURATION_MS / 60000:.1f}')" 2>/dev/null || echo "0")

# Find autotune state files — walk up to git root
find_state_dir() {
  local dir
  dir=$(pwd)
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/.autotune.state" ]]; then
      echo "$dir"
      return
    fi
    if [[ "$dir" == "$git_root" ]]; then
      break
    fi
    dir=$(dirname "$dir")
  done
  echo ""
}

STATE_DIR=$(find_state_dir)

if [[ -z "$STATE_DIR" || ! -f "$STATE_DIR/.autotune.state" ]]; then
  # No autotune session — show minimal info
  printf "\033[90m⏱ %sm · $%s · ctx %s%%\033[0m" "$DURATION_MIN" "$COST" "$CONTEXT_PCT"
  exit 0
fi

# Read autotune state
STATE=$(cat "$STATE_DIR/.autotune.state" 2>/dev/null || echo '{}')

# Parse state fields
python3 - "$STATE" "$DURATION_MIN" "$COST" "$CONTEXT_PCT" <<'PYLINE'
import json
import sys

state = json.loads(sys.argv[1])
duration = sys.argv[2]
cost = sys.argv[3]
ctx = sys.argv[4]

health = state.get("health", "unknown")
experiments = state.get("n_exp", 0)
keep_streak = state.get("keep_streak", 0)
crash_streak = state.get("crash_streak", 0)
no_improve = state.get("no_improve", 0)
healing = state.get("heals", 0)
mode = state.get("mode", "optimize")

# Health state colors
HEALTH_COLORS = {
    "running":   "\033[32m",   # green
    "improving": "\033[32m",   # green
    "plateaued": "\033[33m",   # yellow
    "healing":   "\033[33m",   # yellow
    "crashing":  "\033[31m",   # red
    "paused":    "\033[31m",   # red
}
RESET = "\033[0m"
DIM = "\033[90m"

color = HEALTH_COLORS.get(health, "\033[90m")

# Build status line
parts = []

# Health indicator
health_icon = {
    "running": "●", "improving": "▲", "plateaued": "◆",
    "healing": "⚕", "crashing": "✖", "paused": "⏸",
}.get(health, "?")
parts.append(f"{color}{health_icon} {health}{RESET}")

# Experiment count
parts.append(f"exp {experiments}")

# Streaks
if keep_streak > 0:
    parts.append(f"\033[32m+{keep_streak} kept{RESET}")
if crash_streak > 0:
    parts.append(f"\033[31m{crash_streak} crashes{RESET}")
if no_improve > 0 and health != "running":
    parts.append(f"plateau {no_improve}")
if healing > 0:
    parts.append(f"heal {healing}")

# Session info
parts.append(f"{DIM}{duration}m · ${cost} · ctx {ctx}%{RESET}")

print(" · ".join(parts))
PYLINE
