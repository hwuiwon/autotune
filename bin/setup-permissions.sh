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

# Find marketplace install path if it exists
home = os.path.expanduser("~")
marketplace_path = os.path.join(home, ".claude", "plugins", "marketplaces", "autotune", "bin")

new_perms = [
    f"Bash(bash {autotune_home}/bin/*)",
    "Bash(bash */autotune/bin/*.sh *)",
    "Bash(bash */autotune/bin/*.sh)",
    "Bash(chmod +x autotune*)",
    "Bash(./autotune.sh*)",
    "Bash(./autotune.checks.sh*)",
    "Bash(git checkout -b autotune/*)",
    "Bash(git add autotune*)",
    "Bash(git add .autotune*)",
    "Bash(git add -A -- *)",
    'Bash(git commit -m "autotune:*)',
    "Bash(git log *)",
    "Bash(git diff *)",
    "Bash(git status*)",
    "Bash(git rev-parse *)",
]

# Add marketplace path if it exists
if os.path.isdir(marketplace_path):
    new_perms.insert(0, f"Bash(bash {marketplace_path}/*)")

for p in new_perms:
    if p not in allow:
        allow.append(p)

perms["allow"] = allow
existing["permissions"] = perms

# Configure statusline — chain with existing if present
global_settings_path = os.path.expanduser("~/.claude/settings.json")
existing_sl_cmd = ""
try:
    gs = json.load(open(global_settings_path))
    sl = gs.get("statusLine", {})
    if sl.get("type") == "command":
        existing_sl_cmd = sl.get("command", "")
except Exception:
    pass

# Also check project settings for existing statusline
proj_sl = existing.get("statusLine", {})
if proj_sl.get("type") == "command":
    existing_sl_cmd = proj_sl.get("command", "")

# Build statusline command
sl_script = f"bash {autotune_home}/bin/statusline.sh"
if existing_sl_cmd and "statusline.sh" not in existing_sl_cmd:
    sl_cmd = f"{sl_script} --chain '{existing_sl_cmd}'"
else:
    sl_cmd = sl_script

existing["statusLine"] = {"type": "command", "command": sl_cmd}

with open(settings_file, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")

print(json.dumps({"configured": True, "settings_file": settings_file, "permissions_added": len(new_perms), "statusline": sl_cmd}))
PYMERGE
