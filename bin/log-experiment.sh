#!/usr/bin/env bash
# bin/log-experiment.sh — Log experiment result, handle git commit/revert
#
# Usage:
#   bash log-experiment.sh --commit "abc1234" --metric 150 --status "keep" \
#     --description "optimized hot loop" [--metrics '{"compile_ms":42}'] \
#     [--asi '{"hypothesis":"..."}'] [--force]
#
# Output: Text summary with confidence score

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"
source "$AUTOTUNE_HOME/lib/state.sh"
source "$AUTOTUNE_HOME/lib/git-ops.sh"

# --- Parse args ---
COMMIT=""
METRIC=""
STATUS=""
DESCRIPTION=""
SECONDARY_METRICS="{}"
ASI="{}"
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --metric) METRIC="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --metrics) SECONDARY_METRICS="$2"; shift 2 ;;
    --asi) ASI="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) echo "{\"error\": \"Unknown argument: $1\"}"; exit 1 ;;
  esac
done

# --- Validate ---
if [[ -z "$METRIC" || -z "$STATUS" || -z "$DESCRIPTION" ]]; then
  echo '{"error": "Required: --metric, --status, --description"}'
  exit 1
fi

if [[ "$STATUS" != "keep" && "$STATUS" != "discard" && "$STATUS" != "crash" && "$STATUS" != "checks_failed" ]]; then
  echo '{"error": "Status must be: keep, discard, crash, or checks_failed"}'
  exit 1
fi

# --- Resolve working directory ---
WORKDIR=$(resolve_workdir ".")
JSONL_PATH=$(get_jsonl_path "$WORKDIR")

if [[ ! -f "$JSONL_PATH" ]]; then
  echo '{"error": "No session found. Run init-experiment.sh first."}'
  exit 1
fi

SEGMENT=$(get_current_segment "$JSONL_PATH")
CONFIG=$(get_config_for_segment "$JSONL_PATH" "$SEGMENT")
METRIC_NAME=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('metric_name','metric'))" 2>/dev/null)
METRIC_UNIT=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('metric_unit',''))" 2>/dev/null)
DIRECTION=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('direction','lower'))" 2>/dev/null)

# --- Get commit hash if not provided ---
if [[ -z "$COMMIT" ]]; then
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

# --- Validate secondary metrics consistency ---
VALIDATION=$(python3 -c "
import json, sys

jsonl_path = '$JSONL_PATH'
segment = $SEGMENT
force = $( [[ \"$FORCE\" == \"true\" ]] && echo \"True\" || echo \"False\" )
new_metrics = json.loads('$SECONDARY_METRICS')

# Get existing secondary metric names from this segment
existing_names = set()
current_seg = 0
first_result = True

for line in open(jsonl_path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            current_seg += 1
            continue
        if current_seg == segment and obj.get('type') == 'result':
            if first_result:
                # Baseline establishes the expected set
                existing_names = set(obj.get('metrics', {}).keys())
                first_result = False
    except:
        pass

if not first_result and existing_names:
    # Check for missing metrics
    missing = existing_names - set(new_metrics.keys())
    if missing and not force:
        print(json.dumps({'error': f'Missing secondary metrics: {sorted(missing)}. Use --force to add new metrics.'}))
        sys.exit(0)

    # Check for new metrics
    new_names = set(new_metrics.keys()) - existing_names
    if new_names and not force:
        print(json.dumps({'error': f'New secondary metrics: {sorted(new_names)}. Use --force to add.'}))
        sys.exit(0)

print(json.dumps({'ok': True}))
" 2>/dev/null)

VALIDATION_ERROR=$(echo "$VALIDATION" | python3 -c "import json,sys; v=json.load(sys.stdin); print(v.get('error',''))" 2>/dev/null)
if [[ -n "$VALIDATION_ERROR" ]]; then
  echo "{\"error\": \"$VALIDATION_ERROR\"}"
  exit 1
fi

# --- Git operations ---
GIT_RESULT=""
if [[ "$STATUS" == "keep" ]]; then
  # Auto-commit on keep
  COMMIT_MSG="autotune: $DESCRIPTION"
  GIT_RESULT=$(ar_git_commit "$COMMIT_MSG" "$METRIC_NAME" "$METRIC" "$METRIC_UNIT")
  # Update commit hash from the new commit
  NEW_COMMIT=$(echo "$GIT_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('commit','$COMMIT'))" 2>/dev/null || echo "$COMMIT")
  if [[ -n "$NEW_COMMIT" && "$NEW_COMMIT" != "null" ]]; then
    COMMIT="$NEW_COMMIT"
  fi
else
  # Auto-revert on discard/crash/checks_failed
  GIT_RESULT=$(ar_git_revert "$WORKDIR")
fi

# --- Compute confidence ---
# First append result, then compute (confidence needs this result included)
EXPERIMENT_COUNT=$(count_experiments "$JSONL_PATH" "$SEGMENT")
INDEX=$((EXPERIMENT_COUNT + 1))
TIMESTAMP=$(now_iso)

# --- Append result to JSONL ---
python3 -c "
import json

result = {
    'type': 'result',
    'index': $INDEX,
    'commit': '$COMMIT',
    'metric': $METRIC,
    'status': '$STATUS',
    'description': $(python3 -c "import json; print(json.dumps('$DESCRIPTION'))"),
    'timestamp': '$TIMESTAMP',
    'segment': $SEGMENT,
    'metrics': json.loads('$SECONDARY_METRICS'),
    'asi': json.loads('$ASI')
}
print(json.dumps(result))
" >> "$JSONL_PATH"

# --- Compute confidence ---
CONFIDENCE_JSON=$(python3 "$AUTOTUNE_HOME/lib/confidence.py" "$JSONL_PATH" --segment "$SEGMENT")

# --- Update runtime state ---
update_state_field "$WORKDIR" "experiments_this_session" \
  "$(python3 -c "import json; state=json.load(open('$(get_state_path "$WORKDIR")')); print(state.get('experiments_this_session',0)+1)")"

# --- Check max experiments ---
MAX_EXP=$(read_max_experiments "$WORKDIR")
LIMIT_REACHED=false
if [[ "$MAX_EXP" -gt 0 && "$INDEX" -ge "$MAX_EXP" ]]; then
  LIMIT_REACHED=true
  update_state_field "$WORKDIR" "autotune_mode" "false"
fi

# --- Get baseline for delta computation ---
BASELINE=$(get_baseline "$JSONL_PATH" "$SEGMENT")

# --- Output summary ---
python3 -c "
import json

baseline = float('$BASELINE') if '$BASELINE' else None
metric = $METRIC
direction = '$DIRECTION'
confidence = json.loads('$CONFIDENCE_JSON')

delta = None
delta_pct = None
if baseline is not None and baseline != 0:
    delta = metric - baseline
    delta_pct = round((delta / baseline) * 100, 2)

summary = {
    'status': '$STATUS',
    'index': $INDEX,
    'commit': '$COMMIT',
    'metric': metric,
    'metric_name': '$METRIC_NAME',
    'baseline': baseline,
    'delta': delta,
    'delta_pct': delta_pct,
    'description': $(python3 -c "import json; print(json.dumps('$DESCRIPTION'))"),
    'confidence': confidence,
    'git': json.loads('$GIT_RESULT') if '$GIT_RESULT' else None,
    'limit_reached': $( [[ \"$LIMIT_REACHED\" == \"true\" ]] && echo \"True\" || echo \"False\" ),
}

print(json.dumps(summary, indent=2))
"
