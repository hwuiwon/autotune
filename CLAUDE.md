# autotune

Health-aware autonomous optimization loops for Claude Code.

## Project Structure

- `bin/` — CLI and helper scripts (bash). Each script outputs structured JSON.
- `lib/` — Shared libraries: `state.sh` (state management), `health.py` (health/recovery decisions), `parse-metrics.sh` (METRIC parser), `git-ops.sh` (commit/revert), `confidence.py` (MAD scoring)
- `agents/` — Claude Code plugin subagents. `agents/autotune.md` is the canonical agent definition.
- `skills/` — Claude Code plugin skills. `skills/autotune/SKILL.md` is the canonical setup skill.
- `hooks/` — Claude Code plugin hooks. `hooks/hooks.json` wires `stop.sh` and `pre-tool-use.sh`.
- `.claude-plugin/` — Claude Code marketplace and plugin manifests.
- `templates/` — Templates for autotune.md and autotune.sh

## Conventions

- All bash scripts use `set -euo pipefail` and source `$AUTOTUNE_HOME/lib/state.sh`
- Plugin-facing docs and examples should prefer `${CLAUDE_PLUGIN_ROOT}` for runtime paths.
- Helper scripts (`bin/`) output JSON to stdout for the agent to parse
- The loop is health-aware: recovery is budgeted, explainable, and allowed to pause instead of thrashing forever.
- Plugin-facing instructions should describe `autotune explain` and `autotune repair` whenever loop control is discussed.
- Python is only used for JSON/math operations and health classification
- No external dependencies beyond Python 3 stdlib, git, and bash

## Testing

Validate the plugin:
```bash
claude plugin validate .
cd /tmp && claude --plugin-dir /path/to/autotune agents
uvx ty check lib/health.py
```
