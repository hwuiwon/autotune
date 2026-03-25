#!/usr/bin/env bash
# hooks/pre-tool-use.sh — PreToolUse hook to enforce autotune.sh usage
#
# When autotune.sh exists, validates that run-experiment.sh calls use it.
# Receives JSON on stdin with tool_name and tool_input.
# Exit 0 = allow, exit 2 = block

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"

# Read hook input
INPUT=$(cat)

# Only intercept Bash calls
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# Extract command
COMMAND=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# Only validate run-experiment.sh calls
if ! echo "$COMMAND" | grep -q "run-experiment.sh"; then
  exit 0
fi

# Get working directory
CWD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd','.'))" 2>/dev/null || echo ".")

# Source state for workdir resolution
source "$AUTOTUNE_HOME/lib/state.sh"
WORKDIR=$(resolve_workdir "$CWD")

# Check if autotune.sh exists
if [[ ! -f "$WORKDIR/autotune.sh" ]]; then
  exit 0
fi

# Check if autotune mode is active
if ! is_autotune_active "$WORKDIR"; then
  exit 0
fi

# Extract the --command argument from the run-experiment.sh call
export _AR_CMD="$COMMAND"
EXP_COMMAND=$(python3 -c "
import re, os
cmd = os.environ.get('_AR_CMD', '')
m = re.search(r'--command\s+[\"\x27](.*?)[\"\x27]', cmd)
if m:
    print(m.group(1))
else:
    m = re.search(r'--command\s+(\S+)', cmd)
    if m:
        print(m.group(1))
    else:
        print('')
" 2>/dev/null || echo "")

if [[ -z "$EXP_COMMAND" ]]; then
  exit 0
fi

# Strip env var prefixes and wrappers
STRIPPED=$(echo "$EXP_COMMAND" | sed -E 's/^(env|time|nice|nohup|timeout [0-9]+)\s+//g; s/^[A-Z_]+=[^ ]+ //g')

# Validate it references autotune.sh
if echo "$STRIPPED" | grep -qE '(^|/|\./)autotune\.sh(\s|$)'; then
  exit 0
fi

# Block the call
echo "autotune.sh exists in $WORKDIR. You must use ./autotune.sh as the benchmark command."
exit 2
