"""Check both standalone repair helpers without contacting a Kubernetes cluster.

The kubectl stub records the Job spec and ConfigMap patch. These tests cover
failure boundaries that a syntax check cannot prove; they do not prove that
the real API image, migrations, or cluster permissions work in production.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPERS = ("migration.sh", "fix-skipped-migrations.sh")
KUBECTL_STUB = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["STUB_ROOT"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
mode = os.environ["STUB_MODE"]

if "get" in args and "jobs" in args:
    # A retry gap has zero active Pods but is still eligible to run again.
    prior = {
        "active": {"active": 1},
        "retry_wait": {"active": 0, "failed": 1},
        "unstarted": {},
        "prior_complete": {"succeeded": 1, "conditions": [
            {"type": "Complete", "status": "True"},
        ]},
    }
    print(json.dumps({"items": [{"status": prior[mode]}] if mode in prior else []}))
elif "get" in args and "deploy" in args:
    if args[-1] == "json":
        print(json.dumps({"spec": {"template": {"spec": {
            "serviceAccountName": "tsystem-api",
            "containers": [{"image": "registry.example/transpara/tsystem-api:1.0"}],
        }}}}))
    else:
        print("registry.example/transpara/tsystem-api:1.0")
elif "get" in args and "job" in args:
    if mode == "unobservable":
        raise SystemExit("simulated Kubernetes read failure")
    status = {"succeeded": 1} if mode in ("success", "prior_complete") else (
        {"failed": 1} if mode == "failed" else {})
    print(json.dumps({"status": status}))
elif "get" in args and ("cm" in args or any(arg.startswith("configmap/") for arg in args)):
    if mode == "bad_payload":
        if "tinstaller-state" in args:
            print("0.273.0")
        elif "-l" in args:
            print("configmap/tsystem-upgrade-1")
        else:
            print(json.dumps({"request": {
                "target_version": '0.274.0";__import__("os").system("id")'
            }}))
    else:
        print("0.274.0")
elif "apply" in args:
    (root / "job.json").write_text(sys.stdin.read())
elif "patch" in args:
    (root / "patch.json").write_text(args[args.index("-p") + 1])
elif "logs" in args:
    print("stub Job log")
elif "delete" in args:
    print("job deleted")
else:
    raise SystemExit("unexpected kubectl call: " + repr(args))
"""


def run_helper(helper, mode, *arguments):
    """Run one helper with isolated command stubs and return its recorded effects."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        kubectl = root / "kubectl"
        kubectl.write_text(KUBECTL_STUB)
        kubectl.chmod(0o755)
        # Timeout polling remains bounded but does not cost twenty minutes here.
        sleep = root / "sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n")
        sleep.chmod(0o755)
        environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                           STUB_ROOT=str(root), STUB_MODE=mode, NS="transpara")
        result = subprocess.run(
            ["bash", str(ROOT / helper), *arguments],
            env=environment, text=True, capture_output=True, timeout=40,
        )
        calls_path = root / "calls.jsonl"
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
        job = json.loads((root / "job.json").read_text()) if (root / "job.json").exists() else None
        patch = json.loads((root / "patch.json").read_text()) if (root / "patch.json").exists() else None
        return result, calls, job, patch


class MigrationHelperSafetyTests(unittest.TestCase):
    def test_rejects_injection_and_missing_only_argument_before_creating_job(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                for arguments in (
                    ("0.272.0", '0.274.0";__import__("os").system("id")'),
                    ("--only",),
                    ("--only", "bad-value", "0.272.0", "0.274.0"),
                ):
                    result, calls, job, patch = run_helper(helper, "success", *arguments)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(any("apply" in call for call in calls))
                # The upgrade ConfigMap is a separate input source from CLI arguments.
                result, calls, job, patch = run_helper(
                    helper, "bad_payload", "0.272.0"
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIsNone(job)
                self.assertIsNone(patch)
                self.assertFalse(any("apply" in call for call in calls))

    def test_active_upgrade_blocks_full_and_module_replay(self):
        for helper in HELPERS:
            for mode in ("active", "retry_wait", "unstarted"):
                for prefix in ((), ("--only", "enable_tcache_auth")):
                    with self.subTest(helper=helper, mode=mode, prefix=prefix):
                        result, _, job, patch = run_helper(
                            helper, mode, *prefix, "0.272.0", "0.274.0"
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("unfinished", result.stderr)
                        self.assertIsNone(job)
                        self.assertIsNone(patch)

    def test_terminal_prior_job_allows_replay(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, _, job, patch = run_helper(
                    helper, "prior_complete", "0.272.0", "0.274.0"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(job)
                self.assertIsNotNone(patch)

    def test_success_uses_data_arguments_and_only_full_run_advances_state(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, _, job, patch = run_helper(
                    helper, "success", "0.272.0", "0.274.0"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(job["metadata"]["namespace"], "transpara")
                command = job["spec"]["template"]["spec"]["containers"][0]["command"]
                self.assertEqual(command[0:2], ["python", "-c"])
                self.assertIn("sys.argv[1:6]", command[2])
                self.assertEqual(command[3:], ["0.272.0", "0.274.0", "transpara", "0", ""])
                self.assertEqual(patch, {"data": {"MIGRATIONS_APPLIED_THROUGH": "0.274.0"}})
                for prefix in (("--dry-run",), ("--only", "enable_tcache_auth")):
                    limited, _, _, limited_patch = run_helper(
                        helper, "success", *prefix, "0.272.0", "0.274.0"
                    )
                    self.assertEqual(limited.returncode, 0, limited.stderr)
                    self.assertIsNone(limited_patch)

    def test_failed_timed_out_and_unobservable_jobs_never_advance_state(self):
        for helper in HELPERS:
            for mode in ("failed", "timeout", "unobservable"):
                with self.subTest(helper=helper, mode=mode):
                    result, calls, job, patch = run_helper(
                        helper, mode, "0.272.0", "0.274.0"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNotNone(job)
                    self.assertIsNone(patch)
                    deletes = [call for call in calls if "delete" in call]
                    self.assertEqual(bool(deletes), mode != "failed")
                    for call in deletes:
                        self.assertIn("--cascade=foreground", call)
                        self.assertIn("--wait=true", call)


if __name__ == "__main__":
    unittest.main()
