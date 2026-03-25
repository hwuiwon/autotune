#!/usr/bin/env bash
# bin/run-experiment.sh — Run a benchmark command and parse metrics
#
# Usage:
#   bash run-experiment.sh --command "./autotune.sh" [--timeout 600] [--checks-timeout 300]
#
# Output: JSON with exit_code, duration, metrics, checks results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"
source "$AUTOTUNE_HOME/lib/state.sh"

# --- Parse args ---
COMMAND=""
TIMEOUT=600
CHECKS_TIMEOUT=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command) COMMAND="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --checks-timeout) CHECKS_TIMEOUT="$2"; shift 2 ;;
    *) echo "{\"error\": \"unknown_arg:$1\"}"; exit 1 ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  echo '{"error": "missing:--command"}'
  exit 1
fi

# --- Resolve working directory ---
WORKDIR=$(resolve_workdir ".")
JSONL_PATH=$(get_jsonl_path "$WORKDIR")

# --- Check max experiments ---
if [[ -f "$JSONL_PATH" ]]; then
  MAX_EXP=$(read_max_experiments "$WORKDIR")
  if [[ "$MAX_EXP" -gt 0 ]]; then
    SEGMENT=$(get_current_segment "$JSONL_PATH")
    COUNT=$(count_experiments "$JSONL_PATH" "$SEGMENT")
    if [[ "$COUNT" -ge "$MAX_EXP" ]]; then
      echo "{\"error\": \"max_exp:$MAX_EXP\"}"
      exit 1
    fi
  fi
fi

# --- Guard: enforce autotune.sh if it exists ---
if [[ -f "$WORKDIR/autotune.sh" ]]; then
  # Strip env var prefixes, wrappers like env/time/nice/nohup
  STRIPPED=$(echo "$COMMAND" | sed -E 's/^(env|time|nice|nohup|timeout [0-9]+)\s+//g; s/^[A-Z_]+=[^ ]+ //g')
  if ! echo "$STRIPPED" | grep -qE '(^|/|\./)autotune\.sh(\s|$)'; then
    echo '{"error": "use_autotune_sh"}'
    exit 1
  fi
fi

# --- Get metric name from config ---
METRIC_NAME=""
if [[ -f "$JSONL_PATH" ]]; then
  SEGMENT=$(get_current_segment "$JSONL_PATH")
  CONFIG=$(get_config_for_segment "$JSONL_PATH" "$SEGMENT")
  METRIC_NAME=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('metric_name',''))" 2>/dev/null || echo "")
fi

# --- Run the benchmark ---
TMPOUT=$(mktemp)
trap "rm -f $TMPOUT" EXIT

START_TIME=$(python3 -c "import time; print(time.time())")

EXIT_CODE=0
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  TIMEOUT_CMD=""
fi

TIMED_OUT=false
if [[ -n "$TIMEOUT_CMD" ]]; then
  $TIMEOUT_CMD "$TIMEOUT" bash -c "$COMMAND" > "$TMPOUT" 2>&1 || EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 124 ]]; then
    TIMED_OUT=true
  fi
else
  bash -c "$COMMAND" > "$TMPOUT" 2>&1 || EXIT_CODE=$?
fi

END_TIME=$(python3 -c "import time; print(time.time())")
DURATION=$(python3 -c "print(round($END_TIME - $START_TIME, 3))")

# --- Parse metrics from output ---
METRICS_JSON=$(cat "$TMPOUT" | bash "$AUTOTUNE_HOME/lib/parse-metrics.sh" --primary "$METRIC_NAME")

# --- Determine pass/crash ---
PASSED=false
CRASHED=false
if [[ "$TIMED_OUT" == "true" ]]; then
  CRASHED=true
elif [[ $EXIT_CODE -ne 0 ]]; then
  CRASHED=true
else
  PASSED=true
fi

# --- Tail output (last 50 lines, max 4KB) ---
TAIL_OUTPUT=$(tail -50 "$TMPOUT" | head -c 4096)

# --- Run checks if passed and checks script exists ---
CHECKS_PASS="null"
CHECKS_OUTPUT=""
if [[ "$PASSED" == "true" && -f "$WORKDIR/autotune.checks.sh" ]]; then
  CHECKS_TMP=$(mktemp)
  CHECKS_EXIT=0

  if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD "$CHECKS_TIMEOUT" bash "$WORKDIR/autotune.checks.sh" > "$CHECKS_TMP" 2>&1 || CHECKS_EXIT=$?
  else
    bash "$WORKDIR/autotune.checks.sh" > "$CHECKS_TMP" 2>&1 || CHECKS_EXIT=$?
  fi

  if [[ $CHECKS_EXIT -eq 0 ]]; then
    CHECKS_PASS="true"
  else
    CHECKS_PASS="false"
  fi
  CHECKS_OUTPUT=$(tail -20 "$CHECKS_TMP" | head -c 2048)
  rm -f "$CHECKS_TMP"
fi

# --- Build output JSON ---
python3 -c "
import json, sys

metrics_data = json.loads('''$METRICS_JSON''')
tail_output = sys.stdin.read()

result = {
    'exit': $EXIT_CODE,
    'dur': $DURATION,
    'passed': $( [[ "$PASSED" == "true" ]] && echo "True" || echo "False" ),
    'crashed': $( [[ "$CRASHED" == "true" ]] && echo "True" || echo "False" ),
    'timeout': $( [[ "$TIMED_OUT" == "true" ]] && echo "True" || echo "False" ),
    'metrics': metrics_data.get('metrics', {}),
    'primary': metrics_data.get('primary'),
    'pname': metrics_data.get('pname'),
    'output': tail_output.strip(),
}

checks_pass = '$CHECKS_PASS'
if checks_pass == 'null':
    result['checks'] = None
elif checks_pass == 'true':
    result['checks'] = True
else:
    result['checks'] = False

result['chk_out'] = $(python3 -c "import json; print(json.dumps('''$CHECKS_OUTPUT'''.strip()))")

print(json.dumps(result))
" <<< "$TAIL_OUTPUT"
