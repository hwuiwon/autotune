#!/usr/bin/env bash
# bin/dashboard.sh — Terminal dashboard for autotune experiments
#
# Usage:
#   bash dashboard.sh [--watch] [--full] [--dir PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOTUNE_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTOTUNE_HOME:-$(dirname "$SCRIPT_DIR")}}"
source "$AUTOTUNE_HOME/lib/state.sh"

# --- Parse args ---
WATCH=false
FULL=false
DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH=true; shift ;;
    --full) FULL=true; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

WORKDIR=$(resolve_workdir "$DIR")
JSONL_PATH=$(get_jsonl_path "$WORKDIR")

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

render() {
  if [[ ! -f "$JSONL_PATH" ]]; then
    echo -e "${RED}No autotune session found.${RESET}"
    echo "Run: autotune start"
    return
  fi

  python3 -c "
import json, sys, os

jsonl_path = '$JSONL_PATH'
show_full = $( [[ \"$FULL\" == \"true\" ]] && echo \"True\" || echo \"False\" )
cols = int(os.environ.get('COLUMNS', '120'))

# Colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
BOLD = '\033[1m'
DIM = '\033[2m'
RESET = '\033[0m'

# Parse JSONL
configs = []
results = []
current_seg = 0

for line in open(jsonl_path):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'config':
            current_seg += 1
            configs.append(obj)
        elif obj.get('type') == 'result':
            obj['_segment'] = current_seg
            results.append(obj)
    except:
        pass

if not configs:
    print(f'{RED}No session config found.{RESET}')
    sys.exit(0)

config = configs[-1]
segment = current_seg
seg_results = [r for r in results if r.get('_segment') == segment]

name = config.get('name', 'unnamed')
metric_name = config.get('metric_name', 'metric')
metric_unit = config.get('metric_unit', '')
direction = config.get('direction', 'lower')

# Stats
total = len(seg_results)
kept = sum(1 for r in seg_results if r.get('status') == 'keep')
discarded = sum(1 for r in seg_results if r.get('status') == 'discard')
crashed = sum(1 for r in seg_results if r.get('status') in ('crash', 'checks_failed'))

baseline = seg_results[0]['metric'] if seg_results else None

# Best kept
best = None
if direction == 'lower':
    kept_results = [r for r in seg_results if r.get('status') == 'keep']
    if kept_results:
        best = min(kept_results, key=lambda r: r['metric'])
else:
    kept_results = [r for r in seg_results if r.get('status') == 'keep']
    if kept_results:
        best = max(kept_results, key=lambda r: r['metric'])

# Header
print()
print(f'{BOLD}╔══ Autotune Dashboard ══╗{RESET}')
print(f'{BOLD}║{RESET} {CYAN}{name}{RESET}')
print(f'{BOLD}║{RESET} {metric_name} ({direction} is better) {DIM}unit: {metric_unit}{RESET}')

if len(configs) > 1:
    print(f'{BOLD}║{RESET} Segment {segment} of {len(configs)}')

print(f'{BOLD}╚════════════════════════════╝{RESET}')
print()

# Summary line
status_parts = [
    f'{BOLD}{total}{RESET} runs',
    f'{GREEN}{kept}{RESET} kept',
    f'{YELLOW}{discarded}{RESET} discarded',
]
if crashed > 0:
    status_parts.append(f'{RED}{crashed}{RESET} crashed')

print(f'  ' + ' │ '.join(status_parts))

if baseline is not None:
    print(f'  Baseline: {BOLD}{baseline}{RESET} {metric_unit}')

if best and baseline:
    delta = best['metric'] - baseline
    delta_pct = (delta / baseline * 100) if baseline != 0 else 0
    sign = '+' if delta > 0 else ''
    color = GREEN if (direction == 'lower' and delta < 0) or (direction == 'higher' and delta > 0) else RED
    print(f'  Best:     {color}{BOLD}{best[\"metric\"]}{RESET} {metric_unit} ({sign}{delta_pct:.1f}%) {DIM}[{best.get(\"commit\",\"?\")[:7]}]{RESET}')

print()

# Table
if not seg_results:
    print(f'  {DIM}No experiments yet.{RESET}')
    sys.exit(0)

display_results = seg_results if show_full else seg_results[-20:]
hidden = len(seg_results) - len(display_results)

# Column widths
idx_w = 4
commit_w = 8
metric_w = max(12, len(metric_name) + 2)
status_w = 14
desc_w = max(25, cols - idx_w - commit_w - metric_w - status_w - 12)

# Header
header = f'  {\"#\":<{idx_w}} {\"commit\":<{commit_w}} {metric_name:<{metric_w}} {\"status\":<{status_w}} {\"description\"}'
print(f'{DIM}{header}{RESET}')
print(f'  {\"─\" * (cols - 4)}')

if hidden > 0:
    print(f'  {DIM}... {hidden} earlier experiments hidden (use --full){RESET}')

for r in display_results:
    idx = r.get('index', '?')
    commit = str(r.get('commit', '?'))[:7]
    metric = r.get('metric', '?')
    status = r.get('status', '?')
    desc = r.get('description', '')[:desc_w]

    # Color metric by comparison to baseline
    metric_str = str(metric)
    if baseline is not None and isinstance(metric, (int, float)):
        delta = metric - baseline
        if (direction == 'lower' and delta < 0) or (direction == 'higher' and delta > 0):
            metric_str = f'{GREEN}{metric}{RESET}'
        elif delta != 0:
            metric_str = f'{RED}{metric}{RESET}'

    # Color status
    status_colors = {
        'keep': GREEN,
        'discard': YELLOW,
        'crash': RED,
        'checks_failed': RED,
    }
    sc = status_colors.get(status, '')
    status_str = f'{sc}{status}{RESET}' if sc else status

    # Pad (approximate, ANSI codes don't take width)
    print(f'  {str(idx):<{idx_w}} {commit:<{commit_w}} {metric_str:<{metric_w + 10}} {status_str:<{status_w + 10}} {desc}')

print()
" 2>/dev/null
}

if [[ "$WATCH" == "true" ]]; then
  while true; do
    clear
    render
    sleep 2
  done
else
  render
fi
