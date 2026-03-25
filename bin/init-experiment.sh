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
    *) echo "{\"error\": \"unknown_arg:$1\"}"; exit 1 ;;
  esac
done

if [[ -z "$NAME" || -z "$METRIC_NAME" || -z "$DIRECTION" ]]; then
  echo '{"error": "missing_args"}'
  exit 1
fi

if [[ "$DIRECTION" != "lower" && "$DIRECTION" != "higher" ]]; then
  echo '{"error": "bad_direction"}'
  exit 1
fi

WORKDIR=$(resolve_workdir ".")
JSONL_PATH=$(get_jsonl_path "$WORKDIR")
MAX_EXPERIMENTS=$(read_max_experiments "$WORKDIR")
MODE=$(read_mode "$WORKDIR")

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

CONFIG_FILE_JSON=$(read_config "$WORKDIR")
CONFIG_FILE_JSON="$CONFIG_FILE_JSON" python3 - <<PYCFG >> "$JSONL_PATH"
import json
import os

file_cfg = json.loads(os.environ["CONFIG_FILE_JSON"])
config = {
    "type": "config",
    "name": $(
        python3 -c "import json; print(json.dumps('$NAME'))"
    ),
    "metric_name": $(
        python3 -c "import json; print(json.dumps('$METRIC_NAME'))"
    ),
    "metric_unit": $(
        python3 -c "import json; print(json.dumps('$METRIC_UNIT'))"
    ),
    "direction": "$DIRECTION",
    "segment": $SEGMENT,
    "mode": "$MODE",
    "objective": {
        "primaryMetric": "$METRIC_NAME",
        "direction": "$DIRECTION",
    },
}
if $MAX_EXPERIMENTS > 0:
    config["budget"] = {"maxIterations": $MAX_EXPERIMENTS}
for section in ("health", "recovery", "budget", "evaluator", "guardrails"):
    if isinstance(file_cfg.get(section), dict) and section not in config:
        config[section] = file_cfg[section]
print(json.dumps(config))
PYCFG

init_state "$WORKDIR"

python3 - <<PYOUT
import json

result = {
    "status": "initialized",
    "name": "$NAME",
    "unit": "$METRIC_UNIT",
    "direction": "$DIRECTION",
    "segment": $SEGMENT,
    "reinit": $([[ "$REINIT" == "true" ]] && echo "True" || echo "False"),
    "path": "$JSONL_PATH",
    "max_exp": $MAX_EXPERIMENTS if $MAX_EXPERIMENTS > 0 else None,
    "mode": "$MODE",
}
print(json.dumps(result))
PYOUT
