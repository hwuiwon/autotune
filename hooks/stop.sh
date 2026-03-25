#!/usr/bin/env bash
# hooks/stop.sh — Stop hook for auto-resume
#
# This hook fires when Claude Code stops (context limit, maxTurns, etc.)
# If autotune mode is active, it can auto-resume by launching a new session.
#
# Receives JSON on stdin with session context.
# Config modes (set in autotune.config.json "autoResume"):
#   "headless" — launch new claude session automatically
#   "prompt"   — print instruction for user to resume (default)
#   "off"      — do nothing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"

# Read hook input
INPUT=$(cat)

# Extract working directory from hook input
CWD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd','.'))" 2>/dev/null || echo ".")

# Source state functions
source "$AUTOTUNE_HOME/lib/state.sh"

WORKDIR=$(resolve_workdir "$CWD")
STATE_PATH=$(get_state_path "$WORKDIR")

# Check if autotune is active
if [[ ! -f "$STATE_PATH" ]]; then
  exit 0
fi

STATE=$(cat "$STATE_PATH")

MODE=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('autotune_mode', False))" 2>/dev/null || echo "False")
EXPERIMENTS=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('experiments_this_session', 0))" 2>/dev/null || echo "0")
RESUME_COUNT=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('resume_count', 0))" 2>/dev/null || echo "0")
LAST_RESUME=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_resume_time', 0))" 2>/dev/null || echo "0")

# Must be active with experiments run
if [[ "$MODE" != "True" && "$MODE" != "true" ]]; then
  exit 0
fi

if [[ "$EXPERIMENTS" -eq 0 ]]; then
  exit 0
fi

# Cap at 20 resumes
if [[ "$RESUME_COUNT" -ge 20 ]]; then
  exit 0
fi

# Rate limit: 5 minutes between resumes
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_RESUME))
if [[ "$ELAPSED" -lt 300 && "$LAST_RESUME" -gt 0 ]]; then
  exit 0
fi

# Read auto-resume config
AUTO_RESUME=$(read_config "$WORKDIR" | python3 -c "import json,sys; print(json.load(sys.stdin).get('autoResume', 'prompt'))" 2>/dev/null || echo "prompt")

# Update state
python3 -c "
import json
state = json.load(open('$STATE_PATH'))
state['resume_count'] = state.get('resume_count', 0) + 1
state['last_resume_time'] = $NOW
state['experiments_this_session'] = 0
json.dump(state, open('$STATE_PATH', 'w'), indent=2)
"

# Build resume message
RESUME_MSG="Autotune loop ended (likely context limit). Resume the experiment loop. Read autotune.md and the last entries of autotune.jsonl for context, then continue experimenting."

if [[ -f "$WORKDIR/autotune.ideas.md" ]]; then
  RESUME_MSG="$RESUME_MSG Check autotune.ideas.md for promising ideas to try next."
fi

case "$AUTO_RESUME" in
  headless)
    # Launch new headless Claude session
    cd "$WORKDIR"
    nohup claude -p "$RESUME_MSG" \
      --agent autotune \
      --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
      > /dev/null 2>&1 &
    echo "Autotune auto-resumed in headless mode (resume #$((RESUME_COUNT + 1)))"
    ;;

  prompt)
    # Print instruction for user
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Autotune session paused (context limit reached)"
    echo ""
    echo "  To resume, run:"
    echo "    cd $WORKDIR && claude --agent autotune"
    echo ""
    echo "  Or for headless: autotune start"
    echo "  Resume count: $((RESUME_COUNT + 1))/20"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    ;;

  off|*)
    # Do nothing
    ;;
esac

exit 0
