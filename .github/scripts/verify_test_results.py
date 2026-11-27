"""Require observed ExUnit passes for the application CI jobs."""

import argparse
import json
from pathlib import Path

FEASIBILITY = "test/voelgoed_ai/knowledge_feasibility_test.exs"
FOUNDATION = "test/voelgoed_ai/repo_foundation_test.exs"
SMOKE_FILE = "test/voelgoed_ai/support/shadow_smoke_test.exs"
SMOKE = (SMOKE_FILE, "VoelgoedAi.Support.ShadowSmokeTest", "test owner-approved one-call smoke uses the governed proposal action")
REPO_MODULE = "VoelgoedAi.RepoFoundationTest"
VECTOR = (FOUNDATION, REPO_MODULE, "test the pre-provisioned vector extension executes a cosine distance query")
PREDECESSOR = (FOUNDATION, REPO_MODULE, "test the predecessor upgrade preserves existing staff and audit facts")


def verify(results, mode, paths):
    if not isinstance(results, list) or not results:
        raise ValueError("empty or invalid results report")
    if mode != "shard" and paths != {FOUNDATION}:
        raise ValueError("migration jobs must verify the Repo foundation file")

    observed = {}
    for result in results:
        fields = ("file", "module", "case", "state")
        if not isinstance(result, dict) or any(
            not isinstance(result.get(field), str) or not result[field] for field in fields
        ):
            raise ValueError("malformed ExUnit result")
        file, module, case, state = (result[field] for field in fields)
        identity = (file, module, case)
        if file not in paths or identity in observed:
            raise ValueError(f"unexpected or duplicate result for {file}: {module}.{case}")
        approved_exclusion = identity == SMOKE or (
            identity == PREDECESSOR and mode != "vgas001-upgrade"
        )
        expected = "excluded" if approved_exclusion else "passed"
        if state != expected:
            raise ValueError(f"{file}: {module}.{case} finished as {state}, expected {expected}")
        observed[identity] = state

    passing_files = {file for (file, _, _), state in observed.items() if state == "passed"}
    required_passing_files = paths - {SMOKE_FILE}
    if required_passing_files != passing_files:
        raise ValueError(f"missing passes for: {', '.join(sorted(required_passing_files - passing_files))}")
    if SMOKE_FILE in paths and observed.get(SMOKE) != "excluded":
        raise ValueError("missing explicit exclusion of the live provider smoke case")
    if FEASIBILITY in paths and sum(file == FEASIBILITY for file, _, _ in observed) != 5:
        raise ValueError("expected five passing F04/F05 feasibility cases")
    if FOUNDATION in paths and (observed.get(VECTOR) != "passed" or PREDECESSOR not in observed):
        raise ValueError("missing Repo cosine or predecessor coverage")

    passed = sum(state == "passed" for state in observed.values())
    return passed, len(observed) - passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("mode", choices=("shard", "fresh", "upgrade", "vgas001-upgrade"))
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    try:
        passed, excluded = verify(json.loads(args.report.read_text()), args.mode, set(args.paths))
    except (OSError, ValueError) as error:
        parser.exit(1, f"ExUnit result verification failed: {error}\n")
    print(f"Verified {passed} passes and {excluded} approved exclusions.")
    if FEASIBILITY in args.paths:
        print("Verified five passing F04/F05 feasibility cases.")
