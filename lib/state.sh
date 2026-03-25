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

resolve_workdir() {
  local ctx_cwd="${1:-.}"
  local config
  config=$(read_config "$ctx_cwd")

  local configured_dir
  configured_dir=$(echo "$config" | python3 -c "import sys,json; c=json.load(sys.stdin); print(c.get('workingDir',''))" 2>/dev/null || echo "")

  if [[ -z "$configured_dir" ]]; then
    echo "$ctx_cwd"
    return
  fi

  # Resolve relative to config location
  if [[ "$configured_dir" = /* ]]; then
    echo "$configured_dir"
  else
    echo "$ctx_cwd/$configured_dir"
  fi
}

read_max_experiments() {
  local workdir="${1:-.}"
  local config
  config=$(read_config "$workdir")
  echo "$config" | python3 -c "import sys,json; c=json.load(sys.stdin); print(c.get('maxIterations','0'))" 2>/dev/null || echo "0"
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
  # Count config header lines (type: "config")
  python3 -c "
import json, sys
count = 0
for line in open('$jsonl_path'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            count += 1
    except:
        pass
print(count)
" 2>/dev/null || echo "0"
}

get_baseline() {
  local jsonl_path="$1"
  local segment="$2"
  python3 -c "
import json, sys

segment = int('$segment')
current_seg = 0
baseline = None

for line in open('$jsonl_path'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            current_seg += 1
            continue
        if current_seg == segment and obj.get('type') == 'result':
            baseline = obj.get('metric')
            break
    except:
        pass

if baseline is not None:
    print(baseline)
else:
    print('')
" 2>/dev/null || echo ""
}

count_experiments() {
  local jsonl_path="$1"
  local segment="${2:-}"
  python3 -c "
import json, sys

target_segment = '${segment}' if '${segment}' else None
current_seg = 0
count = 0

if target_segment:
    target_segment = int(target_segment)

for line in open('$jsonl_path'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            current_seg += 1
            continue
        if obj.get('type') == 'result':
            if target_segment is None or current_seg == target_segment:
                count += 1
    except:
        pass

print(count)
" 2>/dev/null || echo "0"
}

get_results_in_segment() {
  # Output all results in the current segment as JSON array
  local jsonl_path="$1"
  local segment="$2"
  python3 -c "
import json, sys

segment = int('$segment')
current_seg = 0
results = []

for line in open('$jsonl_path'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            current_seg += 1
            continue
        if current_seg == segment and obj.get('type') == 'result':
            results.append(obj)
    except:
        pass

print(json.dumps(results))
" 2>/dev/null || echo "[]"
}

get_config_for_segment() {
  local jsonl_path="$1"
  local segment="$2"
  python3 -c "
import json, sys

segment = int('$segment')
current_seg = 0
config = {}

for line in open('$jsonl_path'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            current_seg += 1
            if current_seg == segment:
                config = obj
                break
    except:
        pass

print(json.dumps(config))
" 2>/dev/null || echo "{}"
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
  echo "$current" | python3 -c "
import json, sys
state = json.load(sys.stdin)
field = '$field'
value = '$value'
# Try to parse value as JSON (for numbers, booleans)
try:
    value = json.loads(value)
except:
    pass
state[field] = value
print(json.dumps(state, indent=2))
" > "$state_path"
}

init_state() {
  local workdir="${1:-.}"
  local state_path
  state_path=$(get_state_path "$workdir")
  cat > "$state_path" << 'STATEEOF'
{
  "autotune_mode": true,
  "experiments_this_session": 0,
  "resume_count": 0,
  "last_resume_time": 0
}
STATEEOF
}

is_autotune_active() {
  local workdir="${1:-.}"
  local state
  state=$(read_state "$workdir")
  local mode
  mode=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('autotune_mode', False))" 2>/dev/null || echo "False")
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
