#!/usr/bin/env bash
# bin/log-experiment.sh — Log experiment result, handle git commit/revert

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"
source "$AUTOTUNE_HOME/lib/state.sh"
source "$AUTOTUNE_HOME/lib/git-ops.sh"

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
    *) echo "{\"error\":\"unknown_arg:$1\"}"; exit 1 ;;
  esac
done

if [[ -z "$METRIC" || -z "$STATUS" || -z "$DESCRIPTION" ]]; then
  echo '{"error":"missing_args"}'
  exit 1
fi

if [[ "$STATUS" != "keep" && "$STATUS" != "discard" && "$STATUS" != "crash" && "$STATUS" != "checks_failed" ]]; then
  echo '{"error":"bad_status"}'
  exit 1
fi

WORKDIR=$(resolve_workdir ".")
JSONL_PATH=$(get_jsonl_path "$WORKDIR")
if [[ ! -f "$JSONL_PATH" ]]; then
  echo '{"error":"no_session"}'
  exit 1
fi

SEGMENT=$(get_current_segment "$JSONL_PATH")
CONFIG=$(get_config_for_segment "$JSONL_PATH" "$SEGMENT")
METRIC_NAME=$(CONFIG_JSON="$CONFIG" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["CONFIG_JSON"]).get("metric_name", "metric"))
PY
)
METRIC_UNIT=$(CONFIG_JSON="$CONFIG" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["CONFIG_JSON"]).get("metric_unit", ""))
PY
)
DIRECTION=$(CONFIG_JSON="$CONFIG" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["CONFIG_JSON"]).get("direction", "lower"))
PY
)
STATE_JSON=$(read_state "$WORKDIR")
PREV_SUMMARY=$(segment_summary_json "$JSONL_PATH" "$SEGMENT" "$DIRECTION")
TIMESTAMP=$(now_iso)

if [[ -z "$COMMIT" ]]; then
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

JSONL_PATH_ENV="$JSONL_PATH" SEGMENT_ENV="$SEGMENT" SECONDARY_METRICS_ENV="$SECONDARY_METRICS" FORCE_ENV="$FORCE" python3 - <<'PY' > /tmp/autotune_validation.json
import json
import os

jsonl_path = os.environ["JSONL_PATH_ENV"]
segment = int(os.environ["SEGMENT_ENV"])
force = os.environ["FORCE_ENV"] == "true"
new_metrics = json.loads(os.environ["SECONDARY_METRICS_ENV"])
existing_names = set()
current_seg = 0
first_result = True

for line in open(jsonl_path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "config":
        current_seg += 1
        continue
    if current_seg == segment and obj.get("type") == "result" and first_result:
        existing_names = set(obj.get("metrics", {}).keys())
        first_result = False

if not first_result and existing_names:
    missing = existing_names - set(new_metrics.keys())
    if missing and not force:
        print(json.dumps({"error": f"missing_metrics:{sorted(missing)}"}))
        raise SystemExit(0)
    new_names = set(new_metrics.keys()) - existing_names
    if new_names and not force:
        print(json.dumps({"error": f"new_metrics:{sorted(new_names)}"}))
        raise SystemExit(0)

print(json.dumps({"ok": True}))
PY

VALIDATION_ERROR=$(python3 - <<'PY'
import json

payload = json.load(open("/tmp/autotune_validation.json"))
print(payload.get("error", ""))
PY
)
rm -f /tmp/autotune_validation.json
if [[ -n "$VALIDATION_ERROR" ]]; then
  echo "{\"error\": \"$VALIDATION_ERROR\"}"
  exit 1
fi

FILES_TOUCHED_JSON=$(WORKDIR_ENV="$WORKDIR" python3 - <<'PY'
import json
import os
import subprocess

try:
    out = subprocess.check_output(
        ["git", "-C", os.environ["WORKDIR_ENV"], "status", "--porcelain"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
except Exception:
    print("[]")
    raise SystemExit(0)

paths = []
for line in out.splitlines():
    if not line:
        continue
    path = line[3:]
    if " -> " in path:
        path = path.split(" -> ", 1)[1]
    paths.append(path)
print(json.dumps(sorted(set(paths))))
PY
)

HEALTH_JSON=$(python3 "$AUTOTUNE_HOME/lib/health.py" \
  --previous-summary "$PREV_SUMMARY" \
  --status "$STATUS" \
  --metric "$METRIC" \
  --direction "$DIRECTION" \
  --state "$STATE_JSON" \
  --config "$CONFIG" \
  --timestamp "$TIMESTAMP")

FAILURE_CLASS=$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["HEALTH_JSON"]).get("failure") or "")
PY
)
HEALTH_STATE=$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["HEALTH_JSON"]).get("health", "running"))
PY
)
RECOVERY_ACTION=$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["HEALTH_JSON"]).get("recovery") or "")
PY
)
DECISION_REASON=$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["HEALTH_JSON"]).get("reason") or "")
PY
)
NEXT_MODE=$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["HEALTH_JSON"]).get("mode") or "optimize")
PY
)
STATE_PATCH=$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json
import os

print(json.dumps(json.loads(os.environ["HEALTH_JSON"]).get("patch", {})))
PY
)

GIT_RESULT=""
if [[ "$STATUS" == "keep" ]]; then
  COMMIT_MSG="autotune: $DESCRIPTION"
  GIT_RESULT=$(ar_git_commit "$COMMIT_MSG" "$METRIC_NAME" "$METRIC" "$METRIC_UNIT" "$WORKDIR")
  NEW_COMMIT=$(GIT_RESULT_JSON="$GIT_RESULT" DEFAULT_COMMIT="$COMMIT" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["GIT_RESULT_JSON"]).get("commit", os.environ["DEFAULT_COMMIT"]))
PY
  )
  if [[ -n "$NEW_COMMIT" && "$NEW_COMMIT" != "null" ]]; then
    COMMIT="$NEW_COMMIT"
  fi
else
  GIT_RESULT=$(ar_git_revert "$WORKDIR")
fi

EXPERIMENT_COUNT=$(count_experiments "$JSONL_PATH" "$SEGMENT")
INDEX=$((EXPERIMENT_COUNT + 1))

SECONDARY_METRICS_ENV="$SECONDARY_METRICS" \
ASI_ENV="$ASI" \
FILES_TOUCHED_ENV="$FILES_TOUCHED_JSON" \
FAILURE_CLASS_ENV="$FAILURE_CLASS" \
RECOVERY_ACTION_ENV="$RECOVERY_ACTION" \
DECISION_REASON_ENV="$DECISION_REASON" \
python3 - <<PYAPPEND >> "$JSONL_PATH"
import json
import os

result = {
    "type": "result",
    "index": $INDEX,
    "commit": "$COMMIT",
    "metric": $METRIC,
    "status": "$STATUS",
    "description": $(
        python3 -c "import json; print(json.dumps('$DESCRIPTION'))"
    ),
    "timestamp": "$TIMESTAMP",
    "segment": $SEGMENT,
    "metrics": json.loads(os.environ["SECONDARY_METRICS_ENV"]),
    "asi": json.loads(os.environ["ASI_ENV"]),
    "failure": os.environ["FAILURE_CLASS_ENV"] or None,
    "health": "$HEALTH_STATE",
    "recovery": os.environ["RECOVERY_ACTION_ENV"] or None,
    "reason": os.environ["DECISION_REASON_ENV"],
    "files": json.loads(os.environ["FILES_TOUCHED_ENV"]),
    "mode": "$NEXT_MODE",
}
print(json.dumps(result))
PYAPPEND

CONFIDENCE_JSON=$(python3 "$AUTOTUNE_HOME/lib/confidence.py" "$JSONL_PATH" --segment "$SEGMENT")
set_state_fields "$WORKDIR" "$STATE_PATCH"

STATE_PATH=$(get_state_path "$WORKDIR")
NEXT_EXPERIMENT_COUNT=$(STATE_JSON="$(cat "$STATE_PATH")" python3 - <<'PY'
import json
import os

state = json.loads(os.environ["STATE_JSON"])
print(state.get("n_exp", 0) + 1)
PY
)
update_state_field "$WORKDIR" "n_exp" "$NEXT_EXPERIMENT_COUNT"

MAX_EXP=$(read_max_experiments "$WORKDIR")
LIMIT_REACHED=false
if [[ "$MAX_EXP" -gt 0 && "$INDEX" -ge "$MAX_EXP" ]]; then
  LIMIT_REACHED=true
  set_state_fields "$WORKDIR" '{"active": false, "health": "completed", "reason": "iteration budget reached"}'
fi

BASELINE=$(get_baseline "$JSONL_PATH" "$SEGMENT")

GIT_RESULT_ENV="$GIT_RESULT" \
FAILURE_CLASS_ENV="$FAILURE_CLASS" \
RECOVERY_ACTION_ENV="$RECOVERY_ACTION" \
DECISION_REASON_ENV="$DECISION_REASON" \
CONFIDENCE_JSON_ENV="$CONFIDENCE_JSON" \
python3 - <<PYOUT
import json
import os

baseline = float("$BASELINE") if "$BASELINE" else None
metric = $METRIC
confidence = json.loads(os.environ["CONFIDENCE_JSON_ENV"])
delta = None
delta_pct = None
if baseline is not None and baseline != 0:
    delta = metric - baseline
    delta_pct = round((delta / baseline) * 100, 2)
summary = {
    "status": "$STATUS",
    "index": $INDEX,
    "commit": "$COMMIT",
    "metric": metric,
    "name": "$METRIC_NAME",
    "baseline": baseline,
    "delta": delta,
    "d_pct": delta_pct,
    "desc": $(
        python3 -c "import json; print(json.dumps('$DESCRIPTION'))"
    ),
    "confidence": confidence,
    "git": json.loads(os.environ["GIT_RESULT_ENV"]) if os.environ["GIT_RESULT_ENV"].strip() else None,
    "limit": $([[ "$LIMIT_REACHED" == "true" ]] && echo "True" || echo "False"),
    "health": "$HEALTH_STATE",
    "failure": os.environ["FAILURE_CLASS_ENV"] or None,
    "recovery": os.environ["RECOVERY_ACTION_ENV"] or None,
    "reason": os.environ["DECISION_REASON_ENV"],
    "mode": "$NEXT_MODE",
}
print(json.dumps(summary))
PYOUT
