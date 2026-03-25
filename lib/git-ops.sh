#!/usr/bin/env bash
# lib/git-ops.sh — Git automation for autotune
# Source this file: source "$AUTOTUNE_HOME/lib/git-ops.sh"

set -euo pipefail

# Files that should never be reverted
PROTECTED_FILES=(
  "autotune.jsonl"
  "autotune.md"
  "autotune.ideas.md"
  "autotune.sh"
  "autotune.checks.sh"
  "autotune.config.json"
  ".autotune.state"
)

ar_git_commit() {
  local message="$1"
  local metric_name="${2:-}"
  local metric_value="${3:-}"
  local metric_unit="${4:-}"

  # Build commit message with metric trailers
  local full_message="$message"
  if [[ -n "$metric_name" && -n "$metric_value" ]]; then
    full_message="${full_message}

Autotune-Metric: ${metric_name}=${metric_value}${metric_unit:+ $metric_unit}"
  fi

  # Stage all changes
  git add -A 2>/dev/null || true

  # Check if there's anything to commit
  if git diff --cached --quiet 2>/dev/null; then
    echo '{"committed": false, "reason": "no changes to commit"}'
    return 0
  fi

  # Commit
  local commit_hash
  if git commit -m "$full_message" --quiet 2>/dev/null; then
    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "{\"committed\": true, \"commit\": \"$commit_hash\"}"
  else
    echo '{"committed": false, "reason": "git commit failed"}'
    return 1
  fi
}

ar_git_revert() {
  local workdir="${1:-.}"

  # First, save protected files by staging them
  local has_protected=false
  for f in "${PROTECTED_FILES[@]}"; do
    if [[ -f "$workdir/$f" ]]; then
      git add "$workdir/$f" 2>/dev/null || true
      has_protected=true
    fi
  done

  # Stash protected files if they exist
  if $has_protected; then
    # Store current versions of protected files
    local tmpdir
    tmpdir=$(mktemp -d)
    for f in "${PROTECTED_FILES[@]}"; do
      if [[ -f "$workdir/$f" ]]; then
        cp "$workdir/$f" "$tmpdir/$f"
      fi
    done
  fi

  # Revert all tracked files to HEAD
  git checkout -- "$workdir" 2>/dev/null || true

  # Clean untracked files (except protected)
  local exclude_args=""
  for f in "${PROTECTED_FILES[@]}"; do
    exclude_args="$exclude_args --exclude=$f"
  done
  # shellcheck disable=SC2086
  git clean -fd $exclude_args "$workdir" 2>/dev/null || true

  # Restore protected files
  if $has_protected; then
    for f in "${PROTECTED_FILES[@]}"; do
      if [[ -f "$tmpdir/$f" ]]; then
        cp "$tmpdir/$f" "$workdir/$f"
      fi
    done
    rm -rf "$tmpdir"
  fi

  echo '{"reverted": true}'
}
