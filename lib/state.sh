#!/usr/bin/env bash
# lib/state.sh — Shared functions for autotune
# Source this file from other scripts: source "$AUTOTUNE_HOME/lib/state.sh"

set -euo pipefail

# --- Config ---

read_config() {
  local workdir="${1:-.}"
  local config_file="$workdir/autotune.config.json"
  if [[ -f "$config_file" ]]; then
    cat "$config_file"
  else
    echo '{}'
  fi
}

config_get() {
  local workdir="${1:-.}"
  local path="$2"
  local default_value="${3:-}"
  local config
  config=$(read_config "$workdir")
  CONFIG_JSON="$config" python3 - "$path" "$default_value" <<'PYCONF'
import json
import os
import sys

path = sys.argv[1]
default = sys.argv[2]

try:
    data = json.loads(os.environ["CONFIG_JSON"])
except Exception:
    print(default)
    raise SystemExit(0)

value = data
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print(default)
        raise SystemExit(0)

if value is None:
    print(default)
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PYCONF
}

read_mode() {
  local workdir="${1:-.}"
  config_get "$workdir" "mode" "optimize"
}

read_auto_resume() {
  local workdir="${1:-.}"
  config_get "$workdir" "autoResume" "prompt"
}

read_max_experiments() {
  local workdir="${1:-.}"
  local config
  config=$(read_config "$workdir")
  CONFIG_JSON="$config" python3 - <<'PYMAX'
import json
import os

try:
    cfg = json.loads(os.environ["CONFIG_JSON"])
except Exception:
    print("0")
    raise SystemExit(0)

budget = cfg.get("budget", {}) if isinstance(cfg.get("budget", {}), dict) else {}
value = budget.get("maxIterations", cfg.get("maxIterations", 0))
try:
    print(int(value or 0))
except Exception:
    print("0")
PYMAX
}

resolve_workdir() {
  local ctx_cwd="${1:-.}"
  local configured_dir
  configured_dir=$(config_get "$ctx_cwd" "workingDir" "")

  if [[ -z "$configured_dir" ]]; then
    echo "$ctx_cwd"
    return
  fi

  if [[ "$configured_dir" = /* ]]; then
    echo "$configured_dir"
  else
    echo "$ctx_cwd/$configured_dir"
  fi
}

# --- JSONL State ---

JSONL_FILE="autotune.jsonl"

get_jsonl_path() {
  local workdir="${1:-.}"
  echo "$workdir/$JSONL_FILE"
}

get_current_segment() {
  local jsonl_path="${1}"
  if [[ ! -f "$jsonl_path" ]]; then
    echo "0"
    return
  fi
  python3 - "$jsonl_path" <<'PYSEG' 2>/dev/null || echo "0"
import json
import sys

path = sys.argv[1]
count = 0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get("type") == "config":
            count += 1
    except Exception:
        pass
print(count)
PYSEG
}

get_baseline() {
  local jsonl_path="$1"
  local segment="$2"
  python3 - "$jsonl_path" "$segment" <<'PYBASE' 2>/dev/null || echo ""
import json
import sys

path = sys.argv[1]
segment = int(sys.argv[2])
current_seg = 0
baseline = None
for line in open(path):
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
    if current_seg == segment and obj.get("type") == "result":
        baseline = obj.get("metric")
        break
print("" if baseline is None else baseline)
PYBASE
}

count_experiments() {
  local jsonl_path="$1"
  local segment="${2:-}"
  python3 - "$jsonl_path" "$segment" <<'PYCOUNT' 2>/dev/null || echo "0"
import json
import sys

path = sys.argv[1]
target_segment = sys.argv[2] if len(sys.argv) > 2 else ""
target_segment = int(target_segment) if target_segment else None
current_seg = 0
count = 0
for line in open(path):
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
    if obj.get("type") == "result":
        if target_segment is None or current_seg == target_segment:
            count += 1
print(count)
PYCOUNT
}

get_results_in_segment() {
  local jsonl_path="$1"
  local segment="$2"
  python3 - "$jsonl_path" "$segment" <<'PYRESULTS' 2>/dev/null || echo "[]"
import json
import sys

path = sys.argv[1]
segment = int(sys.argv[2])
current_seg = 0
results = []
for line in open(path):
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
    if current_seg == segment and obj.get("type") == "result":
        results.append(obj)
print(json.dumps(results))
PYRESULTS
}

get_config_for_segment() {
  local jsonl_path="$1"
  local segment="$2"
  python3 - "$jsonl_path" "$segment" <<'PYCFG' 2>/dev/null || echo "{}"
import json
import sys

path = sys.argv[1]
segment = int(sys.argv[2])
current_seg = 0
config = {}
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "config":
        current_seg += 1
        if current_seg == segment:
            config = obj
            break
print(json.dumps(config))
PYCFG
}

segment_summary_json() {
  local jsonl_path="$1"
  local segment="$2"
  local direction="$3"
  python3 - "$jsonl_path" "$segment" "$direction" <<'PYSUM' 2>/dev/null || echo "{}"
import json
import sys

path = sys.argv[1]
segment = int(sys.argv[2])
direction = sys.argv[3]
current_seg = 0
results = []

for line in open(path):
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
    if current_seg == segment and obj.get("type") == "result":
        results.append(obj)

baseline = results[0].get("metric") if results else None
best_kept = None
no_improvement_streak = 0
crash_streak = 0
keep_streak = 0
last_status = None
last_metric = None
last_commit = None
last_description = None

for result in results:
    status = result.get("status")
    metric = result.get("metric")
    last_status = status
    last_metric = metric
    last_commit = result.get("commit")
    last_description = result.get("description")

    if status == "keep":
        improved = best_kept is None
        if best_kept is not None:
            if direction == "higher":
                improved = metric > best_kept
            else:
                improved = metric < best_kept
        if improved:
            best_kept = metric
        no_improvement_streak = 0
        crash_streak = 0
        keep_streak += 1
    elif status == "discard":
        no_improvement_streak += 1
        crash_streak = 0
        keep_streak = 0
    elif status in ("crash", "checks_failed"):
        no_improvement_streak += 1
        crash_streak += 1
        keep_streak = 0
    else:
        keep_streak = 0
        crash_streak = 0

summary = {
    "total_results": len(results),
    "baseline": baseline,
    "best_kept_metric": best_kept,
    "last_status": last_status,
    "last_metric": last_metric,
    "last_commit": last_commit,
    "last_description": last_description,
    "no_improvement_streak": no_improvement_streak,
    "crash_streak": crash_streak,
    "keep_streak": keep_streak,
}
print(json.dumps(summary))
PYSUM
}

# --- Runtime State (.autotune.state) ---

STATE_FILE=".autotune.state"

get_state_path() {
  local workdir="${1:-.}"
  echo "$workdir/$STATE_FILE"
}

read_state() {
  local state_path
  state_path=$(get_state_path "${1:-.}")
  if [[ -f "$state_path" ]]; then
    cat "$state_path"
  else
    echo '{}'
  fi
}

write_state() {
  local state_path
  state_path=$(get_state_path "${1:-.}")
  local state_json="$2"
  echo "$state_json" > "$state_path"
}

update_state_field() {
  local workdir="${1:-.}"
  local field="$2"
  local value="$3"
  local state_path
  state_path=$(get_state_path "$workdir")
  local current
  current=$(read_state "$workdir")
  STATE_JSON="$current" python3 - "$field" "$value" <<'PYSTATE' > "$state_path"
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
field = sys.argv[1]
value = sys.argv[2]
try:
    value = json.loads(value)
except Exception:
    pass
state[field] = value
print(json.dumps(state, indent=2))
PYSTATE
}

set_state_fields() {
  local workdir="${1:-.}"
  local patch_json="$2"
  local state_path
  state_path=$(get_state_path "$workdir")
  local current
  current=$(read_state "$workdir")
  STATE_JSON="$current" python3 - "$patch_json" <<'PYMERGE' > "$state_path"
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
patch = json.loads(sys.argv[1])
state.update(patch)
print(json.dumps(state, indent=2))
PYMERGE
}

init_state() {
  local workdir="${1:-.}"
  local state_path
  state_path=$(get_state_path "$workdir")
  local mode
  mode=$(read_mode "$workdir")
  cat > "$state_path" <<STATEEOF
{
  "autotune_mode": true,
  "operating_mode": "${mode}",
  "health_state": "running",
  "failure_class": null,
  "last_decision_reason": null,
  "last_recovery_action": null,
  "healing_attempts": 0,
  "consecutive_no_improvement": 0,
  "consecutive_failures": 0,
  "crash_streak": 0,
  "keep_streak": 0,
  "experiments_this_session": 0,
  "resume_count": 0,
  "last_resume_time": 0,
  "last_experiment_at": null,
  "last_meaningful_progress_at": null
}
STATEEOF
}

is_autotune_active() {
  local workdir="${1:-.}"
  local state
  state=$(read_state "$workdir")
  local mode
  mode=$(STATE_JSON="$state" python3 - <<'PYACTIVE' 2>/dev/null || echo "False"
import json
import os

print(json.loads(os.environ["STATE_JSON"]).get("autotune_mode", False))
PYACTIVE
)
  [[ "$mode" == "True" || "$mode" == "true" ]]
}

# --- Utilities ---

json_escape() {
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_epoch() {
  date +%s
}
