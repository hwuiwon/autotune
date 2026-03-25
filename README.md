# autotune

Autonomous optimization loops for [Claude Code](https://code.claude.com/docs/en/overview). Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

**Try an idea, measure it, keep what works, repair what breaks, and pause with a reason when the loop gets stuck.**

Works for any optimization target: test speed, bundle size, LLM training loss, build times, Lighthouse scores, inference latency — anything with a number you want to move.

## How It Works

```
┌─────────────────────────────────────────────────┐
│                 Autotune Loop                │
│                                                  │
│ Edit code ─► Benchmark ─► Keep / Revert / Heal  │
│      ▲                           │               │
│      └──── Explain state ◄───────┘               │
│         until budget or pause                    │
└─────────────────────────────────────────────────┘
```

The Claude Code agent autonomously:

1. Analyzes the codebase and picks an optimization to try
2. Makes a focused code change
3. Runs the benchmark (`autotune.sh`)
4. Compares against baseline and guardrails: improved? **keep** (auto-commit). Worse? **discard** (auto-revert)
5. Tracks loop health: improving, plateaued, crashing, healing, paused
6. Applies recovery playbooks with bounded retries, then pauses with an explicit reason if recovery is exhausted
7. Logs experiments, recovery actions, and decisions to `autotune.jsonl`

## What's Included

**Infrastructure** (domain-agnostic):
- `init-experiment.sh` — Initialize a session with metric name, unit, direction
- `run-experiment.sh` — Run benchmark, parse `METRIC name=value` lines, run correctness checks
- `log-experiment.sh` — Log results, auto-commit/revert, compute confidence scores, classify health
- `dashboard.sh` — Terminal dashboard with live monitoring and health state
- `lib/health.py` — Recovery controller and explainable health transitions
- Hooks for auto-resume and benchmark enforcement

**Agent** (the brain):
- `agents/autotune.md` — Full autonomous loop with resume protocol, loop rules, and tool protocol

**Skill** (setup wizard):
- `skills/autotune/SKILL.md` — Gathers goal, writes session files, starts the loop

## Quick Start

### Install as Claude Code Plugin (recommended)

```bash
# Step 1: Add the marketplace
/plugin marketplace add hwuiwon/autotune

# Step 2: Install the plugin
/plugin install autotune@autotune
```

For local development/testing:

```bash
claude --plugin-dir /path/to/autotune
```

### Run

```bash
cd /path/to/your/project

# Interactive — agent asks what to optimize
claude --agent autotune

# Quick start with a goal
claude --agent autotune -p "Optimize test suite speed"
```

### Monitor

In a separate terminal:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-/path/to/autotune}/bin/dashboard.sh" --watch
```

### Stop / Resume

```bash
# Stop the loop (preserves all data)
autotune stop

# Explain the current state and next action
autotune explain

# Force the loop into repair mode
autotune repair

# Resume later
claude --agent autotune

# Clear everything and start fresh
autotune clear
```

## Session Persistence

Two files keep the session alive across restarts and context resets:

- **`autotune.jsonl`** — Append-only log of every experiment (metric, status, commit, description, ASI)
- **`autotune.md`** — Living document: objective, what's been tried, dead ends, key wins
- **`.autotune.state`** — Current operating mode, health state, streaks, and recovery budget

A fresh agent with no memory can read these two files and continue exactly where the previous session left off.

## Confidence Scoring

After 3+ experiments, computes a confidence score using **Median Absolute Deviation** (MAD) as a robust noise estimator:

```
confidence = |best_improvement| / MAD
```

| Score | Label | Meaning |
|-------|-------|---------|
| >= 2.0 | High (green) | Improvement is likely real |
| 1.0-2.0 | Marginal (yellow) | Could be noise — consider re-running |
| < 1.0 | Within noise (red) | Improvement may not be real |

## Health And Recovery

Autotune is not a blind infinite loop anymore. It tracks loop health and switches strategies when the run stops being productive.

Health states:
- `running` / `improving` — normal optimization mode
- `plateaued` — repeated non-improving runs
- `crashing` — benchmark or checks failures are stacking up
- `healing` — a recovery playbook is active
- `paused` — recovery budget is exhausted and the loop stopped safely

Recovery playbooks are configured in priority order and can include:
- `rebaseline`
- `shrink_scope`
- `diagnose`
- `pause`

Use `autotune explain` to see the current health state, last decision reason, and suggested next action.

## Backpressure Checks

Optional `autotune.checks.sh` runs correctness checks after every passing benchmark:

```bash
#!/bin/bash
set -e
pnpm typecheck
pnpm test
pnpm lint
```

If checks fail, the result is logged as `checks_failed` and the changes are reverted.

## Benchmark Script

`autotune.sh` must output structured metrics:

```bash
#!/bin/bash
set -e

# Your benchmark here
result=$(pnpm test --silent 2>/dev/null)

# Output metrics (agent parses these automatically)
echo "METRIC time_ms=1523.4"
echo "METRIC memory_mb=128.5"    # secondary metrics are optional
```

## Auto-Resume

When the agent hits context limits, the Stop hook can automatically resume:

Configure in `autotune.config.json`:

```json
{
  "autoResume": "prompt",
  "maxIterations": 100
}
```

| Mode | Behavior |
|------|----------|
| `prompt` (default) | Prints resume command for the user |
| `headless` | Launches a new `claude -p` session automatically |
| `off` | No auto-resume |

## Configuration

`autotune.config.json` (optional):

```json
{
  "workingDir": "./packages/core",
  "maxIterations": 50,
  "autoResume": "prompt",
  "mode": "optimize",
  "health": {
    "maxNoImprovementRuns": 5,
    "maxCrashStreak": 2
  },
  "recovery": {
    "playbooks": ["rebaseline", "shrink_scope", "diagnose", "pause"],
    "maxHealingAttempts": 3,
    "pauseOnExhaustedRecovery": true
  }
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `workingDir` | Override working directory | Current directory |
| `maxIterations` | Cap experiments per segment | Unlimited |
| `autoResume` | Resume mode: `prompt`, `headless`, `off` | `prompt` |
| `mode` | Initial operating mode: `optimize` or `repair` | `optimize` |
| `health.maxNoImprovementRuns` | Plateau threshold before healing | `5` |
| `health.maxCrashStreak` | Consecutive failures before healing | `2` |
| `recovery.playbooks` | Ordered recovery actions | `["rebaseline","shrink_scope","diagnose","pause"]` |
| `recovery.maxHealingAttempts` | Recovery budget before pause | `3` |
| `recovery.pauseOnExhaustedRecovery` | Stop instead of thrashing forever | `true` |

## CLI Reference

```
autotune <command> [options]

Commands:
  start [goal]          Launch the autotune agent
  stop                  Turn off autotune mode (preserves log)
  clear                 Delete session data and reset
  dashboard [--watch]   Live dashboard (--full for all experiments)
  explain               Show health state, blockers, and next action
  repair                Switch the loop into repair mode
  status                Show current state
  version               Show version
```

## Architecture

```
autotune/
├── .claude-plugin/
│   ├── marketplace.json       # Marketplace metadata
│   └── plugin.json            # Plugin metadata
├── agents/
│   └── autotune.md        # Agent definition
├── bin/
│   ├── autotune           # CLI entry point
│   ├── init-experiment.sh     # Initialize session
│   ├── run-experiment.sh      # Run benchmark + parse metrics
│   ├── log-experiment.sh      # Log result + git commit/revert
│   └── dashboard.sh           # Terminal dashboard
├── lib/
│   ├── state.sh               # Shared functions
│   ├── health.py              # Health controller + explain output
│   ├── parse-metrics.sh       # METRIC line parser
│   ├── git-ops.sh             # Auto-commit/revert
│   └── confidence.py          # MAD-based confidence
├── hooks/
│   ├── stop.sh                # Auto-resume on context limit
│   └── pre-tool-use.sh        # Enforce autotune.sh
├── skills/
│   └── autotune/
│       └── SKILL.md           # Setup skill
└── templates/                 # Session file templates
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Python 3.6+
- Git
- Bash

## License

MIT
