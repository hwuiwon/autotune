#!/usr/bin/env bash
# bin/init-experiment.sh — Initialize an autotune experiment session
#
# Usage:
#   bash init-experiment.sh --name "test-speed" --metric "time_ms" --unit "ms" --direction "lower"
#
# Output: JSON summary of initialized session

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"
source "$AUTOTUNE_HOME/lib/state.sh"

# --- Parse args ---
NAME=""
METRIC_NAME=""
METRIC_UNIT=""
DIRECTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --metric) METRIC_NAME="$2"; shift 2 ;;
    --unit) METRIC_UNIT="$2"; shift 2 ;;
    --direction) DIRECTION="$2"; shift 2 ;;
    *) echo "{\"error\": \"Unknown argument: $1\"}"; exit 1 ;;
  esac
done

# --- Validate ---
if [[ -z "$NAME" || -z "$METRIC_NAME" || -z "$DIRECTION" ]]; then
  echo '{"error": "Required: --name, --metric, --direction"}'
  exit 1
fi

if [[ "$DIRECTION" != "lower" && "$DIRECTION" != "higher" ]]; then
  echo '{"error": "Direction must be \"lower\" or \"higher\""}'
  exit 1
fi

# --- Resolve working directory ---
WORKDIR=$(resolve_workdir ".")
JSONL_PATH=$(get_jsonl_path "$WORKDIR")
MAX_EXPERIMENTS=$(read_max_experiments "$WORKDIR")

# --- Determine segment ---
SEGMENT=1
REINIT=false

if [[ -f "$JSONL_PATH" ]]; then
  EXISTING_SEGMENT=$(get_current_segment "$JSONL_PATH")
  EXISTING_COUNT=$(count_experiments "$JSONL_PATH" "$EXISTING_SEGMENT")
  if [[ "$EXISTING_COUNT" -gt 0 ]]; then
    SEGMENT=$((EXISTING_SEGMENT + 1))
    REINIT=true
  else
    SEGMENT="$EXISTING_SEGMENT"
  fi
fi

# --- Write config header to JSONL ---
CONFIG_LINE=$(python3 -c "
import json
config = {
    'type': 'config',
    'name': $(python3 -c "import json; print(json.dumps('$NAME'))"),
    'metric_name': $(python3 -c "import json; print(json.dumps('$METRIC_NAME'))"),
    'metric_unit': $(python3 -c "import json; print(json.dumps('$METRIC_UNIT'))"),
    'direction': '$DIRECTION',
    'segment': $SEGMENT
}
if $MAX_EXPERIMENTS > 0:
    config['max_experiments'] = $MAX_EXPERIMENTS
print(json.dumps(config))
")

echo "$CONFIG_LINE" >> "$JSONL_PATH"

# --- Initialize runtime state ---
init_state "$WORKDIR"

# --- Output summary ---
python3 -c "
import json
result = {
    'status': 'initialized',
    'name': '$NAME',
    'metric_name': '$METRIC_NAME',
    'metric_unit': '$METRIC_UNIT',
    'direction': '$DIRECTION',
    'segment': $SEGMENT,
    'reinit': $( [[ "$REINIT" == "true" ]] && echo "True" || echo "False" ),
    'jsonl_path': '$JSONL_PATH',
    'max_experiments': $MAX_EXPERIMENTS if $MAX_EXPERIMENTS > 0 else None
}
print(json.dumps(result, indent=2))
"
