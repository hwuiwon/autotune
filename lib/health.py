"""Health classification and recovery decisions for autotune."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from typing import Any


DEFAULT_RECOVERY_PLAYBOOKS = ["rebaseline", "shrink_scope", "diagnose", "pause"]


def coerce_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def coerce_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    return default


def coerce_playbooks(value: Any, default: list[str]) -> list[str]:
    if isinstance(value, list):
        playbooks = [item for item in value if isinstance(item, str)]
        if playbooks:
            return playbooks
    return list(default)


@dataclass(frozen=True)
class HealthConfig:
    max_no_improvement_runs: int = 5
    max_crash_streak: int = 2
    max_flaky_retries: int = 2
    stuck_timeout_seconds: int = 900

    @classmethod
    def from_mapping(cls, value: Any) -> HealthConfig:
        if not isinstance(value, dict):
            return cls()
        return cls(
            max_no_improvement_runs=coerce_int(
                value.get("maxNoImprovementRuns"),
                cls.max_no_improvement_runs,
            ),
            max_crash_streak=coerce_int(
                value.get("maxCrashStreak"),
                cls.max_crash_streak,
            ),
            max_flaky_retries=coerce_int(
                value.get("maxFlakyRetries"),
                cls.max_flaky_retries,
            ),
            stuck_timeout_seconds=coerce_int(
                value.get("stuckTimeoutSeconds"),
                cls.stuck_timeout_seconds,
            ),
        )


@dataclass(frozen=True)
class RecoveryConfig:
    playbooks: list[str] = field(default_factory=lambda: list(DEFAULT_RECOVERY_PLAYBOOKS))
    max_healing_attempts: int = 3
    pause_on_exhausted_recovery: bool = True

    @classmethod
    def from_mapping(cls, value: Any) -> RecoveryConfig:
        defaults = cls()
        if not isinstance(value, dict):
            return defaults
        return cls(
            playbooks=coerce_playbooks(value.get("playbooks"), defaults.playbooks),
            max_healing_attempts=coerce_int(
                value.get("maxHealingAttempts"),
                defaults.max_healing_attempts,
            ),
            pause_on_exhausted_recovery=coerce_bool(
                value.get("pauseOnExhaustedRecovery"),
                defaults.pause_on_exhausted_recovery,
            ),
        )


def choose_playbook(failure_class: str | None, playbooks: list[str], healing_attempts: int) -> str | None:
    preferred = {
        "benchmark_crash": ["reset_worktree", "rebaseline", "diagnose", "pause"],
        "checks_failed": ["diagnose", "rebaseline", "pause"],
        "plateau": ["rebaseline", "shrink_scope", "diagnose", "pause"],
        None: ["diagnose"],
    }.get(failure_class, ["diagnose", "pause"])
    for candidate in preferred:
        if candidate in playbooks:
            return candidate
    return playbooks[min(healing_attempts, len(playbooks) - 1)] if playbooks else None


def advance(previous_summary: dict[str, Any], status: str, metric: float, direction: str, state: dict[str, Any], config: dict[str, Any], timestamp: str) -> dict[str, Any]:
    health_cfg = HealthConfig.from_mapping(config.get("health"))
    recovery_cfg = RecoveryConfig.from_mapping(config.get("recovery"))
    mode = state.get("mode") or config.get("mode") or "optimize"
    prev_best = previous_summary.get("best")
    prev_no_improvement = int(previous_summary.get("no_improve") or 0)
    prev_crash_streak = int(previous_summary.get("crash_streak") or 0)
    prev_keep_streak = int(previous_summary.get("keep_streak") or 0)
    healing_attempts = int(state.get("heals") or 0)

    improved_best = False
    best_kept = prev_best
    no_improvement_streak = prev_no_improvement
    crash_streak = 0
    keep_streak = 0
    failure_class = None
    health_state = "running"
    recovery_action = None
    pause_loop = False
    next_mode = mode

    if status == "keep":
        improved_best = prev_best is None or (metric > prev_best if direction == "higher" else metric < prev_best)
        if improved_best or prev_best is None:
            best_kept = metric
        no_improvement_streak = 0
        crash_streak = 0
        keep_streak = prev_keep_streak + 1
        health_state = "improving" if improved_best else "running"
        next_mode = "optimize"
        healing_attempts = 0
        decision_reason = "improved" if improved_best else "kept_no_degrade"
    elif status == "discard":
        no_improvement_streak = prev_no_improvement + 1
        crash_streak = 0
        keep_streak = 0
        decision_reason = "no_improve"
        if no_improvement_streak >= health_cfg.max_no_improvement_runs:
            failure_class = "plateau"
            health_state = "plateaued"
        else:
            health_state = "running"
    elif status == "checks_failed":
        no_improvement_streak = prev_no_improvement + 1
        crash_streak = prev_crash_streak + 1
        keep_streak = 0
        failure_class = "checks_failed"
        health_state = "crashing"
        decision_reason = "checks_failed"
    else:
        no_improvement_streak = prev_no_improvement + 1
        crash_streak = prev_crash_streak + 1
        keep_streak = 0
        failure_class = "benchmark_crash"
        health_state = "crashing"
        decision_reason = "crash"

    should_heal = False
    if failure_class in {"benchmark_crash", "checks_failed"} and crash_streak >= health_cfg.max_crash_streak:
        should_heal = True
    if failure_class == "plateau":
        should_heal = True

    if should_heal:
        if healing_attempts >= recovery_cfg.max_healing_attempts:
            if recovery_cfg.pause_on_exhausted_recovery:
                pause_loop = True
                health_state = "paused"
                recovery_action = "pause"
                next_mode = "repair"
                decision_reason = "recovery_exhausted"
        else:
            recovery_action = choose_playbook(
                failure_class,
                recovery_cfg.playbooks,
                healing_attempts,
            )
            health_state = "healing"
            next_mode = "repair"
            healing_attempts += 1
            decision_reason = f"heal:{recovery_action}"

    summary = {
        "total": int(previous_summary.get("total") or 0) + 1,
        "baseline": previous_summary.get("baseline", metric),
        "best": best_kept,
        "last_status": status,
        "last_metric": metric,
        "no_improve": no_improvement_streak,
        "crash_streak": crash_streak,
        "keep_streak": keep_streak,
        "improved": improved_best,
    }

    state_patch = {
        "mode": next_mode,
        "health": health_state,
        "failure": failure_class,
        "reason": decision_reason,
        "recovery": recovery_action,
        "heals": healing_attempts,
        "no_improve": no_improvement_streak,
        "failures": crash_streak,
        "crash_streak": crash_streak,
        "keep_streak": keep_streak,
        "exp_at": timestamp,
    }
    if improved_best:
        state_patch["progress_at"] = timestamp
    if pause_loop:
        state_patch["active"] = False

    return {
        "summary": summary,
        "health": health_state,
        "failure": failure_class,
        "recovery": recovery_action,
        "pause": pause_loop,
        "mode": next_mode,
        "reason": decision_reason,
        "patch": state_patch,
    }


def explain(summary: dict[str, Any], state: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    health_state = state.get("health", "running")
    failure_class = state.get("failure")
    action = state.get("recovery")
    if health_state == "healing":
        suggested = action or "diagnose"
    elif health_state == "plateaued":
        suggested = "rebaseline"
    elif health_state == "crashing":
        suggested = "diagnose"
    elif health_state == "paused":
        suggested = "manual_repair"
    else:
        suggested = "continue"

    return {
        "mode": state.get("mode", config.get("mode", "optimize")),
        "health": health_state,
        "failure": failure_class,
        "recovery": action,
        "reason": state.get("reason"),
        "baseline": summary.get("baseline"),
        "best": summary.get("best"),
        "last_metric": summary.get("last_metric"),
        "last_status": summary.get("last_status"),
        "no_improve": state.get("no_improve", summary.get("no_improve", 0)),
        "crash_streak": state.get("crash_streak", summary.get("crash_streak", 0)),
        "keep_streak": state.get("keep_streak", summary.get("keep_streak", 0)),
        "heals": state.get("heals", 0),
        "next": suggested,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--previous-summary")
    parser.add_argument("--summary")
    parser.add_argument("--status")
    parser.add_argument("--metric", type=float)
    parser.add_argument("--direction", default="lower")
    parser.add_argument("--state", default="{}")
    parser.add_argument("--config", default="{}")
    parser.add_argument("--timestamp", default="")
    parser.add_argument("--explain", action="store_true")
    args = parser.parse_args()

    state = json.loads(args.state or "{}")
    config = json.loads(args.config or "{}")

    if args.explain:
        summary = json.loads(args.summary or "{}")
        print(json.dumps(explain(summary, state, config)))
        return

    previous_summary = json.loads(args.previous_summary or "{}")
    print(json.dumps(advance(previous_summary, args.status, args.metric, args.direction, state, config, args.timestamp)))


if __name__ == "__main__":
    main()
