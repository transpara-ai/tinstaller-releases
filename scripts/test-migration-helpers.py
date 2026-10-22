"""Check both standalone repair helpers without contacting a Kubernetes cluster.

The kubectl stub records the Job spec and ConfigMap patch. These tests cover
failure boundaries that a syntax check cannot prove; they do not prove that
the real API image, migrations, or cluster permissions work in production.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPERS = ("migration.sh", "fix-skipped-migrations.sh")
KUBECTL_STUB = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["STUB_ROOT"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
mode = os.environ["STUB_MODE"]
digest = "sha256:" + "a" * 64
image = "registry.example/transpara/tsystem-api:1.0@" + digest

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
elif "get" in args and "crd" in args:
    if mode == "missing_mcp_crd":
        raise SystemExit("simulated absent TransparaMcp CRD")
    print("customresourcedefinition.apiextensions.k8s.io/transparamcps.charts.transpara.com")
elif "get" in args and "transparamcps.charts.transpara.com" in args:
    if mode == "missing_mcp_cr":
        raise SystemExit("simulated absent TransparaMcp CR")
    print("transparamcp.charts.transpara.com/transpara-mcp")
elif "get" in args and "deploy" in args:
    if args[-1] == "json":
        source_image = image
        if mode == "image_unpinned":
            source_image = "registry.example/transpara/tsystem-api:1.0"
        elif mode in ("deploy_changed", "deploy_scheduling_changed"):
            reads = root / "deployment-reads"
            count = int(reads.read_text()) + 1 if reads.exists() else 1
            reads.write_text(str(count))
            if mode == "deploy_changed" and count > 1:
                source_image = "registry.example/transpara/tsystem-api:1.0@sha256:" + "b" * 64
        spec = {"containers": [{"name": "api", "image": source_image}]}
        if mode == "deploy_scheduling_changed" and count > 1:
            # The Job must use the second Deployment read that passed the
            # rollout check, not the first read used to derive the registry.
            spec["nodeSelector"] = {"nodepool": "api"}
        if mode == "success_security_context":
            spec["securityContext"] = {
                "runAsNonRoot": True, "runAsUser": 1001, "fsGroup": 1001,
                "seccompProfile": {"type": "RuntimeDefault"},
            }
            spec["runtimeClassName"] = "gvisor"
            spec["hostUsers"] = False
            spec["containers"][0]["securityContext"] = {
                "allowPrivilegeEscalation": False,
                "capabilities": {"drop": ["ALL"]},
                "readOnlyRootFilesystem": True,
            }
        if mode == "success_scheduling":
            spec.update({
                "nodeSelector": {"nodepool": "api"},
                "tolerations": [{"key": "dedicated", "operator": "Equal",
                                 "value": "api", "effect": "NoSchedule"}],
                "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [{"matchExpressions": [{"key": "nodepool",
                        "operator": "In", "values": ["api"]}]}]}}},
                "priorityClassName": "api-critical", "schedulerName": "custom-scheduler",
                "topologySpreadConstraints": [{"maxSkew": 1, "topologyKey": "zone",
                    "whenUnsatisfiable": "DoNotSchedule", "labelSelector": {
                        "matchLabels": {"app": "tsystem-api"}}}],
            })
        if mode != "success_default_sa":
            spec["serviceAccountName"] = "tsystem-api"
        if mode == "success_automount_off":
            spec["automountServiceAccountToken"] = False
        elif mode == "success_automount_on":
            spec["automountServiceAccountToken"] = True
        print(json.dumps({
            "metadata": {"generation": 2},
            "spec": {"replicas": 1, "selector": (
                {"matchExpressions": [{"key": "app", "operator": "In", "values": ["tsystem-api"]}]}
                if mode == "selector_expressions" else
                {"matchLabels": {"app": "tsystem-api"}}),
                     "template": {"spec": spec}},
            "status": {"observedGeneration": 1 if mode == "rollout_pending" else 2,
                       "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1},
        }))
    else:
        print(image)
elif "get" in args and "pods" in args:
    pod = {
        "metadata": {"name": "tsystem-api-1", "deletionTimestamp": (
            "2026-10-20T00:00:00Z" if mode == "pod_terminating" else None)},
        "spec": {"containers": [{"name": "api", "image": image}]},
        "status": {"conditions": [{"type": "Ready", "status": (
            "False" if mode == "pod_not_ready" else "True")}],
                   "containerStatuses": [{"name": "api", "ready": mode != "pod_not_ready",
                                          "imageID": "registry.example/transpara/tsystem-api@" + (
                                              "sha256:" + "b" * 64 if mode == "pod_old_digest"
                                              else digest)}]},
    }
    print(json.dumps({"items": [pod]}))
elif "get" in args and "job" in args:
    if mode == "unobservable":
        raise SystemExit("simulated Kubernetes read failure")
    successful_modes = (
        "success", "success_default_sa", "success_automount_off",
        "success_automount_on", "success_security_context", "success_scheduling",
        "deploy_scheduling_changed",
        "prior_complete", "lock_hold", "patch_unknown",
        "missing_mcp_cr", "missing_mcp_crd",
        "marker_advanced", "marker_race", "marker_below_bridge",
    )
    status = {"succeeded": 1} if mode in successful_modes else (
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
    elif "tinstaller-state" in args and args[-1] == "json":
        # Each full apply reads once before the Job and once after success.
        reads = root / "state-reads"
        count = int(reads.read_text()) + 1 if reads.exists() else 1
        reads.write_text(str(count))
        marker = ("0.273.0" if mode == "marker_below_bridge" else
                  "0.274.0-alpha.beta" if mode == "marker_mixed_prerelease" else
                  "0.300.0" if mode == "marker_ahead" or
                  (mode == "marker_advanced" and count == 2) else
                  "0.274.0-alpha.01.a" if mode == "marker_zero_padded" else
                  "invalid!" if mode == "marker_invalid" else "0.274.0")
        print(json.dumps({"metadata": {"resourceVersion": "1"},
                          "data": {"INSTALLER_VERSION": "0.274.0",
                                   "MIGRATIONS_APPLIED_THROUGH": marker}}))
    else:
        print("0.274.0")
elif "create" in args and "configmap" in args:
    # O_EXCL models the API server's atomic create of a named lock object.
    try:
        fd = os.open(root / "replay.lock", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise SystemExit("replay lock already exists")
    with os.fdopen(fd, "w") as lock:
        lock.write(next((arg.split("=", 1)[1] for arg in args if arg.startswith("--from-literal=holder=")), ""))
    if mode == "lock_hold":
        # Keep the first process at the API boundary until the test confirms
        # that the second process was rejected. A fixed sleep is timing-sensitive.
        deadline = time.monotonic() + 10
        while not (root / "release-first").exists():
            if time.monotonic() >= deadline:
                raise SystemExit("test did not release the first lock holder")
            time.sleep(0.01)
elif "apply" in args:
    (root / "job.json").write_text(sys.stdin.read())
    if mode == "apply_unknown":
        raise SystemExit("simulated response failure after Job submission")
elif "patch" in args:
    patch = json.loads(args[args.index("-p") + 1])
    assert "--type" in args and args[args.index("--type") + 1] == "json"
    assert patch[0] == {"op": "test", "path": "/metadata/resourceVersion", "value": "1"}
    (root / "patch.json").write_text(json.dumps(patch))
    if mode == "marker_race":
        # Another writer advanced the state after the helper's final read.
        raise SystemExit("resourceVersion test failed")
    if mode == "patch_unknown":
        raise SystemExit("simulated response failure after state patch")
elif "logs" in args:
    print("stub Job log")
elif "delete" in args:
    if "configmap" in args:
        (root / "replay.lock").unlink()
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
        locked = (root / "replay.lock").exists()
        return result, calls, job, patch, locked


def run_emitted_dry_run(job, modern_runner):
    """Execute the Job's Python against the legacy and current runner shapes.

    This isolates the embedded program from Kubernetes and HTTP access. The
    live-cluster qualification checks the real image and API behavior separately.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for package in ("kubernetes", "app", "app/upgrade", "app/upgrade/migrations"):
            path = root / package
            path.mkdir(parents=True)
            (path / "__init__.py").write_text("")
        (root / "kubernetes/config.py").write_text(
            "def load_incluster_config():\n    pass\n"
        )
        (root / "yaml.py").write_text("")
        (root / "httpx.py").write_text("")
        # The 0.274.0 runner holds one module per version in an OrderedDict
        # and has no pending_versions. Later runners use a list that can keep
        # two modules at the same version and expose pending_versions.
        runner = '''from collections import OrderedDict
MODERN = @MODERN@

class OtherMigration:
    __module__ = "m_0_271_0_other"

class TargetMigration:
    __module__ = "m_0_272_0_target"

class SecondTargetMigration:
    __module__ = "m_0_272_0_second_target"

class BaseRunner:
    def __init__(self):
        pairs = [("0.271.0", OtherMigration()), ("0.272.0", TargetMigration())]
        self.migrations = (pairs + [("0.272.0", SecondTargetMigration())]
                           if MODERN else OrderedDict(pairs))

    def load(self, path):
        pass

    def _pending(self, current, target):
        # Fixed fixture versions keep ordering unambiguous; this stub checks
        # the collection and method contract, not semantic version parsing.
        pairs = self.migrations if MODERN else self.migrations.items()
        return ((version, migration) for version, migration in pairs
                if current < version <= target)

class ModernRunner(BaseRunner):
    def pending_versions(self, current, target):
        return [version for version, _ in self._pending(current, target)]

class LegacyRunner(BaseRunner):
    pass

ClusterMigrationRunner = ModernRunner if MODERN else LegacyRunner
'''.replace("@MODERN@", repr(modern_runner))
        (root / "app/upgrade/migrations/runner.py").write_text(runner)
        command = job["spec"]["template"]["spec"]["containers"][0]["command"]
        assert command[:2] == ["python", "-c"]
        return subprocess.run(
            [sys.executable, *command[1:]],
            env=dict(os.environ, PYTHONPATH=str(root)), text=True,
            capture_output=True, timeout=5,
        )


class MigrationHelperSafetyTests(unittest.TestCase):
    def test_targeted_mcp_replay_checks_crd_and_cr_without_patching_marker(self):
        # --only filters Python module paths by substring. Every selector
        # that can choose the published MCP module must keep its safety
        # checks, while an unrelated repair remains possible on its own.
        for helper in HELPERS:
            for selector in ("transpara_mcp", "m_0_272_0", "install",
                             "m_0_272_0_install_transpara_mcp"):
                with self.subTest(helper=helper, selector=selector):
                    blocked, _, job, patch, locked = run_helper(
                        helper, "missing_mcp_crd", "--only", selector,
                        "0.270.0", "0.274.0"
                    )
                    self.assertNotEqual(blocked.returncode, 0)
                    self.assertIn("install the target operator CRDs", blocked.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(locked)
                    incomplete, _, job, patch, locked = run_helper(
                        helper, "missing_mcp_cr", "--only", selector,
                        "0.270.0", "0.274.0"
                    )
                    self.assertNotEqual(incomplete.returncode, 0)
                    self.assertIsNotNone(job)
                    self.assertIsNone(patch)
                    self.assertTrue(locked)
                    self.assertIn("replay lock remains", incomplete.stderr)
            repaired, _, job, patch, locked = run_helper(
                helper, "success", "--only", "transpara_mcp", "0.270.0", "0.274.0"
            )
            self.assertEqual(repaired.returncode, 0, repaired.stderr)
            self.assertIsNotNone(job)
            self.assertIsNone(patch)
            self.assertFalse(locked)
            other, _, job, patch, locked = run_helper(
                helper, "missing_mcp_crd", "--only", "enable_tcache_auth",
                "0.270.0", "0.274.0"
            )
            self.assertEqual(other.returncode, 0, other.stderr)
            self.assertIsNotNone(job)
            self.assertIsNone(patch)
            self.assertFalse(locked)

    def test_crossing_0_272_requires_mcp_crd_before_job(self):
        # A direct pre-bridge upgrade can update the operator image without
        # installing its CRD. Stop before a replay restarts tauth or holds a
        # lock that cannot be cleared without manual inspection.
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, calls, job, patch, locked = run_helper(
                    helper, "missing_mcp_crd", "0.270.0", "0.274.0"
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("install the target operator CRDs", result.stderr)
                self.assertIsNone(job)
                self.assertIsNone(patch)
                self.assertFalse(locked)
                self.assertFalse(any("create" in call for call in calls))

    def test_crossing_0_272_checks_mcp_cr_before_marker_patch(self):
        # A terminal Job alone cannot establish that a required custom
        # resource exists; a failed postcondition retains the replay lock.
        for helper in HELPERS:
            for mode in ("success", "missing_mcp_cr"):
                with self.subTest(helper=helper, mode=mode):
                    result, _, job, patch, locked = run_helper(
                        helper, mode, "0.270.0", "0.274.0"
                    )
                    self.assertIsNotNone(job)
                    self.assertEqual(result.returncode == 0, mode == "success")
                    self.assertEqual(patch is not None, mode == "success")
                    self.assertEqual(locked, mode == "missing_mcp_cr")
                    if mode == "missing_mcp_cr":
                        self.assertIn("replay lock remains", result.stderr)

    def test_rejects_reversed_or_equal_version_window_before_creating_job(self):
        # A zero-work Job must never be allowed to write an older or equal
        # target into the installer migration marker.
        for helper in HELPERS:
            for prefix in ((), ("--dry-run",), ("--only", "target")):
                for source, target in (
                    ("0.274.0", "0.274.0"),
                    ("0.280.0", "0.274.0"),
                    ("0.274.0-rc.1", "0.274.0-rc.1"),
                    ("0.274.0-alpha.beta", "0.274.0-alpha.1"),
                    ("0.274.0-alpha.100000000000000000000", "0.274.0-alpha.2"),
                ):
                    with self.subTest(helper=helper, prefix=prefix, source=source, target=target):
                        result, calls, job, patch, locked = run_helper(
                            helper, "success", *prefix, source, target
                        )
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn("FROM must be earlier", result.stderr)
                        self.assertIsNone(job)
                        self.assertIsNone(patch)
                        self.assertFalse(locked)
                        self.assertFalse(any("create" in call for call in calls))

    def test_full_apply_does_not_regress_ahead_or_concurrently_changed_marker(self):
        for helper in HELPERS:
            for mode in ("marker_ahead", "marker_invalid", "marker_zero_padded",
                         "marker_advanced",
                         "marker_race", "marker_mixed_prerelease"):
                with self.subTest(helper=helper, mode=mode):
                    target = "0.274.0-alpha.1" if mode == "marker_mixed_prerelease" else "0.274.0"
                    result, calls, job, patch, locked = run_helper(
                        helper, mode, "0.272.0", target
                    )
                    self.assertNotEqual(result.returncode, 0)
                    if mode in ("marker_ahead", "marker_invalid", "marker_zero_padded",
                                "marker_mixed_prerelease"):
                        self.assertIsNone(job)
                        self.assertFalse(locked)
                        self.assertFalse(any("create" in call for call in calls))
                    else:
                        self.assertIsNotNone(job)
                        self.assertTrue(locked)
                        if mode == "marker_advanced":
                            self.assertIn("replay lock", result.stderr)
                    self.assertEqual(patch is not None, mode == "marker_race")
                    self.assertFalse(any("delete" in call and "configmap" in call for call in calls))

    def test_prerelease_window_accepts_a_release_as_a_later_target(self):
        for helper in HELPERS:
            for source, target in (("0.274.0-rc.1", "0.274.0"),
                                   ("0.274.0-alpha.1", "0.274.0-alpha.beta"),
                                   ("0.274.0-alpha", "0.274.0-alpha.1")):
                with self.subTest(helper=helper, source=source, target=target):
                    result, _, job, patch, locked = run_helper(
                        helper, "success", "--dry-run", source, target
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIsNotNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(locked)

    def test_prerelease_below_bridge_blocks_real_replay_but_allows_dry_run(self):
        # A prerelease sorts below its base release and cannot satisfy the
        # 0.274.0 bridge. Dry-run may inspect it but must not advance state.
        for helper in HELPERS:
            for prefix in ((), ("--only", "target")):
                with self.subTest(helper=helper, prefix=prefix):
                    result, calls, job, patch, locked = run_helper(
                        helper, "marker_below_bridge", *prefix,
                        "0.273.0", "0.274.0-alpha.1"
                    )
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("nothing to replay", result.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(locked)
                    self.assertFalse(any("create" in call for call in calls))
            result, _, job, patch, locked = run_helper(
                helper, "marker_below_bridge", "--dry-run",
                "0.273.0", "0.274.0-alpha.1"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNotNone(job)
            self.assertIsNone(patch)
            self.assertFalse(locked)

    def test_prerelease_precedence_matches_numeric_and_text_identifier_rules(self):
        # This is the SemVer precedence chain. Adjacent pairs exercise the
        # comparator through each helper's public CLI in both directions.
        ordered = (
            "0.274.0-alpha", "0.274.0-alpha.1", "0.274.0-alpha.beta",
            "0.274.0-beta", "0.274.0-beta.2", "0.274.0-beta.11",
            "0.274.0-rc.1", "0.274.0",
        )
        for helper in HELPERS:
            for earlier, later in zip(ordered, ordered[1:]):
                with self.subTest(helper=helper, earlier=earlier, later=later):
                    forward, _, job, _, _ = run_helper(
                        helper, "success", "--dry-run", earlier, later
                    )
                    self.assertEqual(forward.returncode, 0, forward.stderr)
                    self.assertIsNotNone(job)
                    reverse, _, job, patch, locked = run_helper(
                        helper, "success", "--dry-run", later, earlier
                    )
                    self.assertEqual(reverse.returncode, 2, reverse.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(locked)

    def test_rejects_injection_and_missing_only_argument_before_creating_job(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                for arguments in (
                    ("0.272.0", '0.274.0";__import__("os").system("id")'),
                    ("--only",),
                    ("--only", "bad-value", "0.272.0", "0.274.0"),
                    ("0.272.0", "0.274.0-alpha..beta"),
                ):
                    result, calls, job, patch, _ = run_helper(helper, "success", *arguments)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(any("apply" in call for call in calls))
                # The upgrade ConfigMap is a separate input source from CLI arguments.
                result, calls, job, patch, _ = run_helper(
                    helper, "bad_payload", "0.272.0"
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIsNone(job)
                self.assertIsNone(patch)
                self.assertFalse(any("apply" in call for call in calls))

    def test_rejects_zero_padded_numeric_versions_before_creating_job(self):
        # A padded prerelease identifier could compare equal to its unpadded
        # form and skip a later identifier, allowing a marker regression.
        for helper in HELPERS:
            for source, target in (
                ("00.272.0", "0.274.0"),
                ("0.272.0", "0.0274.0"),
                ("0.272.0-alpha.01.a", "0.274.0"),
                ("0.272.0", "0.274.0-alpha.01.a"),
                ("0.272.0", "0.274.0-alpha.00"),
            ):
                with self.subTest(helper=helper, source=source, target=target):
                    result, calls, job, patch, locked = run_helper(
                        helper, "success", source, target
                    )
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("safe release versions", result.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(locked)
                    self.assertFalse(any("create" in call for call in calls))

    def test_active_upgrade_blocks_full_and_module_replay(self):
        for helper in HELPERS:
            for mode in ("active", "retry_wait", "unstarted"):
                for prefix in ((), ("--only", "enable_tcache_auth")):
                    with self.subTest(helper=helper, mode=mode, prefix=prefix):
                        result, _, job, patch, _ = run_helper(
                            helper, mode, *prefix, "0.272.0", "0.274.0"
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("unfinished", result.stderr)
                        self.assertIsNone(job)
                        self.assertIsNone(patch)

    def test_terminal_prior_job_allows_replay(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, _, job, patch, locked = run_helper(
                    helper, "prior_complete", "0.272.0", "0.274.0"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(job)
                self.assertIsNotNone(patch)
                self.assertFalse(locked)

    def test_atomic_lock_blocks_simultaneous_entry_points(self):
        # The first command holds the lock while its stub waits. The second
        # command uses the compatibility entry point against the same namespace.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            kubectl = root / "kubectl"
            kubectl.write_text(KUBECTL_STUB)
            kubectl.chmod(0o755)
            environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                               STUB_ROOT=str(root), STUB_MODE="lock_hold", NS="transpara")
            first = subprocess.Popen(
                ["bash", str(ROOT / HELPERS[0]), "0.272.0", "0.274.0"],
                env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            try:
                deadline = time.monotonic() + 5
                while not (root / "replay.lock").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "replay.lock").exists(), "first helper never acquired lock")
                second = subprocess.run(
                    ["bash", str(ROOT / HELPERS[1]), "0.272.0", "0.274.0"],
                    env=environment, text=True, capture_output=True, timeout=5,
                )
                self.assertNotEqual(second.returncode, 0)
                self.assertIn("replay lock", second.stderr)
                self.assertNotIn("waiting for job/", second.stdout)
            finally:
                (root / "release-first").write_text("")
                stdout, stderr = first.communicate(timeout=5)
            self.assertEqual(first.returncode, 0, stderr + stdout)
            self.assertFalse((root / "replay.lock").exists())

    def test_success_uses_data_arguments_and_only_full_run_advances_state(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, _, job, patch, locked = run_helper(
                    helper, "success", "0.272.0", "0.274.0"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(job["metadata"]["namespace"], "transpara")
                # The API server must stop a stranded privileged Job even if
                # the shell process disappears before its client-side timeout.
                self.assertEqual(job["spec"]["activeDeadlineSeconds"], 1200)
                command = job["spec"]["template"]["spec"]["containers"][0]["command"]
                self.assertEqual(command[0:2], ["python", "-c"])
                self.assertIn("sys.argv[1:6]", command[2])
                self.assertEqual(command[3:], ["0.272.0", "0.274.0", "transpara", "0", ""])
                self.assertEqual(patch, [
                    {"op": "test", "path": "/metadata/resourceVersion", "value": "1"},
                    {"op": "add", "path": "/data/MIGRATIONS_APPLIED_THROUGH", "value": "0.274.0"},
                ])
                self.assertFalse(locked)
                for prefix in (("--dry-run",), ("--only", "enable_tcache_auth")):
                    limited, _, _, limited_patch, limited_locked = run_helper(
                        helper, "success", *prefix, "0.272.0", "0.274.0"
                    )
                    self.assertEqual(limited.returncode, 0, limited.stderr)
                    self.assertIsNone(limited_patch)
                    self.assertFalse(limited_locked)

    def test_replay_preserves_deployment_service_account_settings(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                explicit, _, explicit_job, _, _ = run_helper(
                    helper, "success", "0.272.0", "0.274.0"
                )
                self.assertEqual(explicit.returncode, 0, explicit.stderr)
                self.assertEqual(explicit_job["spec"]["template"]["spec"]["serviceAccountName"], "tsystem-api")
                self.assertNotIn("automountServiceAccountToken", explicit_job["spec"]["template"]["spec"])

                default, _, default_job, _, _ = run_helper(
                    helper, "success_default_sa", "0.272.0", "0.274.0"
                )
                self.assertEqual(default.returncode, 0, default.stderr)
                self.assertNotIn("serviceAccountName", default_job["spec"]["template"]["spec"])
                self.assertNotIn("automountServiceAccountToken", default_job["spec"]["template"]["spec"])

                for mode, expected in (("success_automount_off", False),
                                       ("success_automount_on", True)):
                    with self.subTest(mode=mode):
                        result, _, job, _, _ = run_helper(
                            helper, mode, "0.272.0", "0.274.0"
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIs(
                            job["spec"]["template"]["spec"]["automountServiceAccountToken"],
                            expected,
                        )

    def test_replay_preserves_pod_and_container_security_contexts(self):
        # The replay Job copies the source Pod's credentials and mounted
        # volumes. Its migrate and added init containers must retain the
        # source runtime restrictions rather than use image defaults.
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, _, job, _, _ = run_helper(
                    helper, "success_security_context", "0.272.0", "0.274.0"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                pod = job["spec"]["template"]["spec"]
                self.assertEqual(pod["securityContext"], {
                    "runAsNonRoot": True, "runAsUser": 1001, "fsGroup": 1001,
                    "seccompProfile": {"type": "RuntimeDefault"},
                })
                self.assertEqual(pod["runtimeClassName"], "gvisor")
                self.assertIs(pod["hostUsers"], False)
                expected_container = {
                    "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]},
                    "readOnlyRootFilesystem": True,
                }
                self.assertEqual(pod["containers"][0]["securityContext"], expected_container)
                self.assertEqual(pod["initContainers"][-1]["securityContext"], expected_container)

                default, _, default_job, _, _ = run_helper(
                    helper, "success", "0.272.0", "0.274.0"
                )
                self.assertEqual(default.returncode, 0, default.stderr)
                default_pod = default_job["spec"]["template"]["spec"]
                for field in ("securityContext", "runtimeClassName", "hostUsers"):
                    self.assertNotIn(field, default_pod)
                self.assertNotIn("securityContext", default_pod["containers"][0])
                self.assertNotIn("securityContext", default_pod["initContainers"][-1])

    def test_replay_preserves_source_pod_scheduling_requirements(self):
        # A Job with the same identity and volumes must remain schedulable on
        # dedicated API nodes; absent source constraints must stay absent.
        fields = ("nodeSelector", "tolerations", "affinity", "priorityClassName",
                  "schedulerName", "topologySpreadConstraints")
        for helper in HELPERS:
            with self.subTest(helper=helper):
                result, _, job, _, _ = run_helper(
                    helper, "success_scheduling", "0.272.0", "0.274.0"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                pod = job["spec"]["template"]["spec"]
                self.assertEqual(pod["nodeSelector"], {"nodepool": "api"})
                self.assertEqual(pod["tolerations"][0]["effect"], "NoSchedule")
                self.assertEqual(pod["affinity"]["nodeAffinity"]
                                 ["requiredDuringSchedulingIgnoredDuringExecution"]
                                 ["nodeSelectorTerms"][0]["matchExpressions"][0]["values"],
                                 ["api"])
                self.assertEqual(pod["priorityClassName"], "api-critical")
                self.assertEqual(pod["schedulerName"], "custom-scheduler")
                self.assertEqual(pod["topologySpreadConstraints"][0]["topologyKey"], "zone")
                default, _, default_job, _, _ = run_helper(
                    helper, "success", "0.272.0", "0.274.0"
                )
                self.assertEqual(default.returncode, 0, default.stderr)
                for field in fields:
                    self.assertNotIn(field, default_job["spec"]["template"]["spec"])
                changed, _, changed_job, _, _ = run_helper(
                    helper, "deploy_scheduling_changed", "0.272.0", "0.274.0"
                )
                self.assertEqual(changed.returncode, 0, changed.stderr)
                self.assertEqual(changed_job["spec"]["template"]["spec"]
                                 ["nodeSelector"], {"nodepool": "api"})

    def test_replay_waits_for_actual_api_digest_convergence(self):
        # Deployment status and Pod image IDs both matter. An upgrade Job can
        # finish while old or unready API Pods still serve requests.
        for helper in HELPERS:
            for mode in ("rollout_pending", "pod_old_digest", "pod_not_ready",
                         "pod_terminating", "image_unpinned", "deploy_changed",
                         "selector_expressions"):
                with self.subTest(helper=helper, mode=mode):
                    result, calls, job, patch, locked = run_helper(
                        helper, mode, "0.272.0", "0.274.0"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("API", result.stderr)
                    self.assertIsNone(job)
                    self.assertIsNone(patch)
                    self.assertFalse(locked)
                    self.assertFalse(any("apply" in call for call in calls))

    def test_emitted_job_supports_legacy_and_current_runner_contracts(self):
        for helper in HELPERS:
            for selector in ((), ("--only", "target")):
                with self.subTest(helper=helper, selector=selector):
                    result, _, job, _, _ = run_helper(
                        helper, "success", "--dry-run", *selector, "0.270.0", "0.274.0"
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for modern in (False, True):
                        with self.subTest(modern=modern):
                            executed = run_emitted_dry_run(job, modern)
                            self.assertEqual(executed.returncode, 0, executed.stderr)
                            expected = (["0.272.0"] * (2 if modern else 1)
                                        if selector else ["0.271.0", "0.272.0"]
                                        + (["0.272.0"] if modern else []))
                            self.assertIn("PENDING " + json.dumps(expected), executed.stdout)
            # A module can exist in the image yet fall outside the requested
            # version window; report that instead of returning false success.
            result, _, job, _, _ = run_helper(
                helper, "success", "--dry-run", "--only", "target", "0.272.0", "0.274.0"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            for modern in (False, True):
                with self.subTest(helper=helper, modern=modern, out_of_range=True):
                    executed = run_emitted_dry_run(job, modern)
                    self.assertNotEqual(executed.returncode, 0)
                    self.assertIn("pending", executed.stderr)

    def test_failed_timed_out_and_unobservable_jobs_keep_lock_without_advancing_state(self):
        for helper in HELPERS:
            for mode in ("failed", "timeout", "unobservable"):
                with self.subTest(helper=helper, mode=mode):
                    result, calls, job, patch, locked = run_helper(
                        helper, mode, "0.272.0", "0.274.0"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNotNone(job)
                    self.assertIsNone(patch)
                    # A terminal failure or confirmed deletion does not prove
                    # that earlier migration steps left no cluster mutations.
                    self.assertTrue(locked)
                    self.assertIn("replay lock", result.stderr)
                    self.assertFalse(any("delete" in call and "configmap" in call for call in calls))
                    deletes = [call for call in calls if "delete" in call and "job" in call]
                    self.assertEqual(bool(deletes), mode != "failed")
                    for call in deletes:
                        self.assertIn("--cascade=foreground", call)
                        self.assertIn("--wait=true", call)

    def test_uncertain_apply_and_patch_keep_lock_for_operator_inspection(self):
        # A client error can arrive after the API server accepted the request.
        # Releasing the lock here could start a second Job or repeat a patch.
        for helper in HELPERS:
            for mode in ("apply_unknown", "patch_unknown"):
                with self.subTest(helper=helper, mode=mode):
                    result, calls, job, patch, locked = run_helper(
                        helper, mode, "0.272.0", "0.274.0"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNotNone(job)
                    self.assertEqual(patch is not None, mode == "patch_unknown")
                    self.assertTrue(locked)
                    self.assertFalse(any("delete" in call and "configmap" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
