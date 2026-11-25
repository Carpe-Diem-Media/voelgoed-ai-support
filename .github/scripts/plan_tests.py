"""Balance whole ExUnit files using timings from a successful main run."""

import hashlib
import json
import math
import statistics
from pathlib import Path


def fingerprint(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def plan(paths, history, limit=8):
    weights = {}
    for path in paths:
        entry = history.get(path)
        if not isinstance(entry, dict) or entry.get("digest") != fingerprint(path):
            continue
        seconds = entry.get("seconds")
        if type(seconds) in (int, float) and math.isfinite(seconds) and seconds > 0:
            weights[path] = seconds

    fallback = max(5, statistics.median_high(sorted(weights.values()))) if weights else 5
    shards = [{"shard": index + 1, "files": []} for index in range(min(limit, len(paths)))]
    totals = [0] * len(shards)
    for path in sorted(paths, key=lambda path: (-weights.get(path, fallback), path)):
        index = min(range(len(shards)), key=lambda index: (totals[index], index))
        shards[index]["files"].append(path)
        totals[index] += weights.get(path, fallback)
    return {"include": shards}


if __name__ == "__main__":
    history = {}
    for report in sorted(Path("timing-history").glob("*/timing.json")):
        try:
            entries = json.loads(report.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(entries, dict):
            history.update(entries)
    paths = sorted(str(path) for path in Path("test").rglob("*_test.exs") if path.is_file())
    matrix = plan(paths, history)
    print(f"matrix={json.dumps(matrix, separators=(',', ':'))}")
    print(f"has_tests={str(bool(paths)).lower()}")
