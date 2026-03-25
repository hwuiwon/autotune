---
name: autotune
description: Set up and run an autonomous experiment loop to optimize any metric
---

# Autotune Setup Skill

You are setting up an autotune session — an autonomous optimization loop that will edit code, benchmark, keep improvements, and revert regressions forever.

## Step 1: Gather Information

Ask the user (or infer from context) the following:

1. **Goal**: What are we optimizing? (e.g., "test suite speed", "bundle size", "inference latency")
2. **Command**: What command runs the benchmark? (e.g., `pnpm test`, `make bench`, `python train.py`)
3. **Metric**: What metric to extract from the output?
   - Name (e.g., `time_ms`, `size_kb`, `loss`)
   - Unit (e.g., `ms`, `KB`, ``)
   - Direction: `lower` or `higher` is better?
4. **Files in scope**: Which files/directories can be modified?
5. **Constraints**: Any correctness requirements? (e.g., "tests must still pass", "types must check")

If the user provided a clear goal in their prompt, you can infer reasonable defaults and confirm rather than asking many questions.

## Step 2: Create Branch

```bash
git checkout -b autotune/<goal-slug>-$(date +%Y%m%d)
```

## Step 3: Read Source Files

Read all files in scope. Understand the workload deeply before writing anything. This understanding is critical for generating good optimization ideas.

## Step 4: Write Session Files

### `autotune.md`

Write the living session document:

```markdown
# Autotune: <goal>

## Objective
<what we're optimizing and why>

## Setup
- **Command**: `./autotune.sh`
- **Metric**: <name> (<unit>, <direction> is better)
- **Files in scope**: <list>
- **Constraints**: <constraints or "none">

## What's Been Tried
(nothing yet)

## Dead Ends
(none yet)

## Key Wins
(none yet)

## Current Best
Baseline: pending first run
```

### `autotune.sh`

Write the benchmark script. It MUST:
- Output `METRIC <name>=<value>` on stdout
- Exit 0 on success, non-zero on failure
- Be as fast as possible (skip unnecessary work)
- For noisy benchmarks, run multiple iterations and report the median

Example for test speed:
```bash
#!/bin/bash
set -e

# Run tests and capture timing
start=$(python3 -c "import time; print(time.time())")
pnpm test --silent 2>/dev/null
end=$(python3 -c "import time; print(time.time())")
elapsed=$(python3 -c "print(round(($end - $start) * 1000, 1))")

echo "METRIC time_ms=$elapsed"
```

Example for bundle size:
```bash
#!/bin/bash
set -e
pnpm build --silent 2>/dev/null
size=$(du -sb dist/ | awk '{print $1}')
echo "METRIC size_bytes=$size"
```

Make it executable: `chmod +x autotune.sh`

### `autotune.checks.sh` (optional)

If the user specified correctness constraints, write a checks script:

```bash
#!/bin/bash
set -e
pnpm typecheck
pnpm test
pnpm lint
```

Make it executable: `chmod +x autotune.checks.sh`

## Step 5: Initialize and Run Baseline

```bash
# Initialize
bash ${CLAUDE_PLUGIN_ROOT}/bin/init-experiment.sh \
  --name "<goal-slug>" \
  --metric "<metric_name>" \
  --unit "<unit>" \
  --direction "<lower|higher>"

# Run baseline
bash ${CLAUDE_PLUGIN_ROOT}/bin/run-experiment.sh --command "./autotune.sh"

# Log baseline (use the parsed_primary value from run output)
bash ${CLAUDE_PLUGIN_ROOT}/bin/log-experiment.sh \
  --metric <baseline_value> \
  --status keep \
  --description "baseline" \
  [--metrics '<secondary_metrics_json>']
```

## Step 6: Commit Session Files

```bash
git add autotune.md autotune.sh autotune.jsonl .autotune.state
git add autotune.checks.sh 2>/dev/null || true
git commit -m "autotune: initialize session for <goal>"
```

## Step 7: Start the Loop

Immediately begin the autotune loop. Generate your first optimization idea based on your understanding of the source code, and start experimenting.

**LOOP FOREVER. Never ask "should I continue?".**

The loop:
1. Think about what to try (based on code understanding, past results, ideas backlog)
2. Make ONE focused code change
3. Run: `bash ${CLAUDE_PLUGIN_ROOT}/bin/run-experiment.sh --command "./autotune.sh"`
4. Evaluate: improved → keep, same/worse → discard, crashed → crash
5. Log: `bash ${CLAUDE_PLUGIN_ROOT}/bin/log-experiment.sh --metric <value> --status <status> --description "<what you tried>"`
6. Update autotune.md every 3-5 experiments
7. GOTO 1

**NEVER STOP.** The user may be away for hours.
