#!/usr/bin/env bash
# lib/parse-metrics.sh — Parse METRIC name=value lines from command output
# Usage: echo "$output" | bash parse-metrics.sh [--primary METRIC_NAME]
# Output: JSON object of parsed metrics

set -euo pipefail

PRIMARY_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary) PRIMARY_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

python3 -c "
import sys, json, math

REJECTED_NAMES = {'__proto__', 'constructor', 'prototype'}
primary_name = '${PRIMARY_NAME}'

metrics = {}
primary_value = None

for line in sys.stdin:
    line = line.strip()
    if not line.startswith('METRIC '):
        continue

    rest = line[7:]  # Remove 'METRIC ' prefix
    eq_idx = rest.find('=')
    if eq_idx < 0:
        continue

    name = rest[:eq_idx].strip()
    value_str = rest[eq_idx+1:].strip()

    # Reject dangerous names
    if name in REJECTED_NAMES or not name:
        continue

    # Parse value
    try:
        value = float(value_str)
        if not math.isfinite(value):
            continue
        metrics[name] = value
    except (ValueError, OverflowError):
        continue

# Determine primary
if primary_name and primary_name in metrics:
    primary_value = metrics[primary_name]
elif not primary_name and metrics:
    # First metric is primary if no name specified
    primary_value = next(iter(metrics.values()))

result = {
    'metrics': metrics,
    'primary': primary_value,
    'pname': primary_name if primary_name else (next(iter(metrics.keys())) if metrics else None)
}

print(json.dumps(result))
"
