#!/usr/bin/env python3
"""MAD-based confidence scoring for autotune.

Usage:
    python3 confidence.py <jsonl_path> [--segment N]

Output: JSON with confidence score, label, and color.
"""

import json
import sys
from pathlib import Path


def median(values: list[float]) -> float:
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2


def mad(values: list[float]) -> float:
    """Median Absolute Deviation — robust noise estimator."""
    med = median(values)
    deviations = [abs(v - med) for v in values]
    return median(deviations)


def compute_confidence(
    results: list[dict], direction: str
) -> dict:
    """Compute confidence score from experiment results.

    Args:
        results: List of result dicts with 'metric' and 'status' fields
        direction: 'lower' or 'higher'

    Returns:
        Dict with 'confidence', 'label', 'color' fields
    """
    # Need at least 3 data points
    metrics = [r["metric"] for r in results if r.get("metric") is not None]
    if len(metrics) < 3:
        return {"confidence": None, "label": "insufficient_data", "color": "gray"}

    baseline = metrics[0]
    noise = mad(metrics)

    if noise == 0:
        # No noise at all — either all identical or only one unique value
        kept = [r for r in results if r.get("status") == "keep"]
        if kept:
            best_metric = kept[-1].get("metric", baseline)
            delta = best_metric - baseline
            if (direction == "lower" and delta < 0) or (
                direction == "higher" and delta > 0
            ):
                return {
                    "confidence": float("inf"),
                    "label": "high",
                    "color": "green",
                }
        return {"confidence": 0.0, "label": "no_signal", "color": "red"}

    # Find best improvement among kept results
    kept = [r for r in results if r.get("status") == "keep" and r.get("metric") is not None]
    if not kept:
        return {"confidence": 0.0, "label": "no_kept", "color": "red"}

    if direction == "lower":
        best_metric = min(r["metric"] for r in kept)
        best_delta = baseline - best_metric  # positive = improvement
    else:
        best_metric = max(r["metric"] for r in kept)
        best_delta = best_metric - baseline  # positive = improvement

    confidence = abs(best_delta) / noise

    # Classify
    if confidence >= 2.0:
        label, color = "high", "green"
    elif confidence >= 1.0:
        label, color = "marginal", "yellow"
    else:
        label, color = "within_noise", "red"

    return {
        "confidence": round(confidence, 3),
        "label": label,
        "color": color,
        "best_metric": best_metric,
        "best_delta": round(best_delta, 6),
        "noise_mad": round(noise, 6),
    }


def load_results(jsonl_path: str, segment: int | None = None) -> tuple[list[dict], str]:
    """Load results from jsonl file, optionally filtering by segment."""
    results = []
    direction = "lower"
    current_seg = 0

    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            if obj.get("type") == "config":
                current_seg += 1
                if segment is None or current_seg == segment:
                    direction = obj.get("direction", "lower")
                continue

            if obj.get("type") == "result":
                if segment is None or current_seg == segment:
                    results.append(obj)

    return results, direction


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: confidence.py <jsonl_path> [--segment N]"}))
        sys.exit(1)

    jsonl_path = sys.argv[1]
    segment = None

    if "--segment" in sys.argv:
        idx = sys.argv.index("--segment")
        if idx + 1 < len(sys.argv):
            segment = int(sys.argv[idx + 1])

    if not Path(jsonl_path).exists():
        print(json.dumps({"confidence": None, "label": "no_data", "color": "gray"}))
        sys.exit(0)

    results, direction = load_results(jsonl_path, segment)
    score = compute_confidence(results, direction)
    print(json.dumps(score))


if __name__ == "__main__":
    main()
