#!/usr/bin/env bash
# bin/setup-permissions.sh — Add scoped autotune permissions to target project
# Writes to .claude/settings.local.json so autotune scripts run without prompts.

set -euo pipefail

AUTOTUNE_HOME="${AUTOTUNE_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

TARGET_DIR="${1:-.}"
SETTINGS_DIR="$TARGET_DIR/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.local.json"

mkdir -p "$SETTINGS_DIR"

# Read existing settings or start fresh
if [[ -f "$SETTINGS_FILE" ]]; then
  EXISTING=$(cat "$SETTINGS_FILE")
else
  EXISTING='{}'
fi

# Merge permissions without duplicates
AUTOTUNE_HOME="$AUTOTUNE_HOME" python3 - "$EXISTING" "$SETTINGS_FILE" <<'PYMERGE'
import json
import os
import sys

existing = json.loads(sys.argv[1])
settings_file = sys.argv[2]
autotune_home = os.environ.get("AUTOTUNE_HOME", "")

perms = existing.get("permissions", {})
allow = perms.get("allow", [])

new_perms = [
    f"Bash(bash {autotune_home}/bin/*)",
    "Bash(bash ${CLAUDE_PLUGIN_ROOT}/bin/*)",
    "Bash(chmod +x autotune*)",
    "Bash(./autotune.sh*)",
    "Bash(./autotune.checks.sh*)",
    "Bash(git checkout -b autotune/*)",
    "Bash(git add autotune*)",
    "Bash(git add .autotune*)",
    'Bash(git commit -m "autotune:*)',
    "Bash(git log *)",
    "Bash(git diff *)",
    "Bash(git status*)",
    "Bash(git rev-parse *)",
]

for p in new_perms:
    if p not in allow:
        allow.append(p)

perms["allow"] = allow
existing["permissions"] = perms

with open(settings_file, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")

print(json.dumps({"configured": True, "settings_file": settings_file, "permissions_added": len(new_perms)}))
PYMERGE
