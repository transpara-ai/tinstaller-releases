---
doc_id: TINSTALLER-RELEASES-README
title: tInstaller releases quickstart and migration repair
doc_type: readme
status: draft
version: 0.2.1
created: 2025-08-13
updated: 2026-10-21
owner: Transpara AI
steward: Codex
project: tInstaller Releases
supersedes: []
canonical: false
---

# Quickstart

## Install k3s

```bash
bash <(curl -sfL https://github.com/transpara/tinstaller-releases/releases/latest/download/get-and-run.sh) install-k3s
```

## Install tsystem and essentials
 
```bash
source ~/.bashrc && bash <(curl -sfL https://github.com/transpara/tinstaller-releases/releases/latest/download/get-and-run.sh) install-tsystem
```

# Uninstall

## Clean up system (uninstall k3s and remove leftovers)

```bash
curl -sfL https://github.com/transpara/tinstaller-releases/releases/latest/download/uninstall.sh | bash -s -- --nuke-k3s
```

## Remove transpara components without affecting the rest of the cluster

```bash
curl -sfL https://github.com/transpara/tinstaller-releases/releases/latest/download/uninstall.sh | bash -s --
```

# Repair: migrations skipped by a direct upgrade from < 0.274.0

These repair helpers replay cluster migrations that a direct upgrade from
before 0.274.0 may skip (for example, `secret "tcache-auth" not found`).
Inspect the script and confirm the original and target
versions before running it on an authorized control-plane node. The default
original version is 0.272.0; pass a different version when needed.

```bash
bash migration.sh --dry-run 0.270.0
bash migration.sh 0.270.0
```

For a replay selecting the 0.272.0 MCP migration, first check that
`transparamcps.charts.transpara.com` exists. A full installed 0.270.0 to
0.274.0 qualification found that the direct API upgrade updated the operator
image and marked its 0.272.0 migration complete without installing this CRD.
The target operator's CRD must be installed through the approved operator
deployment process before replay. Verify it is established with
`kubectl wait --for=condition=Established crd/transparamcps.charts.transpara.com --timeout=60s`.
The helpers reject a full apply or matching `--only` apply before creating a
Job when the CRD is absent. After a successful Job, they also require the
`transpara-mcp` custom resource before reporting success; a full replay then
advances the installer migration marker. A missing resource retains the replay
lock for inspection. An unrelated `--only` selector keeps its independent
repair path. A matching selector is any substring of the published module name
`m_0_272_0_install_transpara_mcp`. A dry-run lists pending migrations without
requiring the CRD; it does not prove that an apply can succeed.

`--dry-run` does not invoke the pre- or post-upgrade migrations, but it still
creates a Kubernetes Job using the API deployment's service account, images,
environment and volumes to list pending migrations. The Job has a 20-minute
API-server deadline, even if the helper process disappears, and a 24-hour
cleanup TTL after completion. The client also waits for about 20 minutes;
failed or unobservable Jobs retain the replay lock. Running either command
changes the cluster and requires separate operational authorization.
`--only <module-substr>`
replays matching migration modules and does not advance `MIGRATIONS_APPLIED_THROUGH`.

`fix-skipped-migrations.sh` remains available as a standalone compatibility
entry point for existing commands that pipe it directly to Bash; prefer
`migration.sh` for new use. Its safety logic is copied deliberately because a
remote wrapper cannot rely on `migration.sh` being present on the operator's
machine. Both copies receive the same safety tests. Both scripts reject
malformed versions, reversed or equal version windows, and invalid module
selectors.
The version-window check compares numeric release and prerelease identifiers
by SemVer precedence, including a numeric identifier before a text identifier.
Numeric core and prerelease identifiers with leading zeroes are invalid; both
helpers reject them before creating a Job or advancing the migration marker.
Real replays also require a target that is at least 0.274.0 by SemVer, so a
target such as 0.274.0-alpha.1 is rejected before Job creation. A dry-run may
inspect that prerelease target; it still creates a Job, but skips migration
steps and does not advance the marker.
This check scans the version text once and adds no Kubernetes request. Its
latency has not been measured separately; time a long accepted tag on the
target control-plane host if validation cost becomes material.
They stop if an upgrade or another replay Job lacks a terminal Complete or
Failed condition (including gaps between Pod retries). They also require all
desired API replicas to be updated, Ready and available, and every selected
API Pod to be Ready on the Deployment's pinned SHA-256 image digest. Old or
terminating Pods, an unpinned image, or an unsupported selector blocks replay
before Job creation. A disposable qualification observed a 30–89-second gap
between upgrade Job completion and full API Pod digest convergence; see the
[PR 5 qualification](docs/pr5-qualification.md). The guard
uses two Deployment reads and one selected-Pod list per invocation; production
API latency and load have not been measured. The helpers create an atomic
`tinstaller-migrations-replay-lock` ConfigMap before
starting a replay Job. The lock prevents two helper invocations from starting
concurrent Jobs. The operator running either helper needs namespace access to:

- get the `tsystem-api` Deployment;
- get and list ConfigMaps, create/delete the replay-lock ConfigMap, and patch
  `tinstaller-state` (the upgrade-record lookup also lists ConfigMaps);
- get/list/create/patch/delete Jobs, and watch Jobs and ConfigMaps while
  foreground deletion or lock cleanup completes;
- get/list Pods and get Pod logs for `kubectl logs job/<name>`; and
- for replays selecting the 0.272.0 MCP migration, get the cluster-scoped
  TransparaMcp CRD and the `transpara-mcp` custom resource in the target
  namespace.

The replay Job uses the API Deployment's service-account identity and needs its
own migration permissions. A named account is copied exactly. An explicit
`automountServiceAccountToken: false` or `true` is also copied, so a source Pod
that suppresses bearer-token mounting cannot accidentally gain one in the Job.
The source Pod's `securityContext`, `runtimeClassName` and `hostUsers` are
copied when present. The API container's `securityContext` is copied to both
the replay and added `load-migrations` containers. This preserves user/group,
seccomp, capability, sandbox and read-only-filesystem restrictions around the
copied credentials and volumes. Missing source settings stay omitted. A
restricted identity may be unable to write the shared migration volume; such
a Job fails and retains its lock. Qualify the migration image under the source
Deployment's restrictions in a disposable cluster. Copying these fields adds
no API requests; its scheduling and runtime cost has not been measured on a
cluster with explicit restrictions.
The Job also copies the source Pod's node selector, tolerations, affinity,
priority class, scheduler and topology-spread constraints when present. This
keeps it eligible for the API workload's intended nodes. An inherited
constraint can still leave it unschedulable if capacity or policy changes;
the server deadline stops it and the lock remains. Copying these fields adds
no API reads. A disposable Kind Job completed with a tainted node, node
selector, affinity, toleration, priority class and topology spread; see the
[PR 5 qualification](docs/pr5-qualification.md). That fixture does not
measure scheduling latency or capacity on production dedicated nodes.
The migration runner uses in-cluster Kubernetes access; when automount is
disabled and no other authorized Kubernetes credentials are supplied, the Job
will fail and the helper will leave the migration state unchanged. Qualify a
compatible identity in a disposable cluster before replay.
If the Deployment omits `serviceAccountName`, the Job omits it too and
Kubernetes selects the namespace's `default` account; the helper never
substitutes a more privileged account. Omitted automount settings remain
omitted. The helper does not grant
either identity access.

The published 0.274.0 API image stores migrations in an ordered map and has no
`pending_versions` method. Newer runners use a list, which can keep multiple
modules at one version, and expose that method. Both helpers preserve the
runner's storage type when filtering `--only` and use its own version-window
logic when the public method is absent. A selector outside `(FROM, TO]` fails
instead of reporting an empty successful replay. Qualify the API and migration
images for the intended target release in a disposable cluster before replay.

This adds one lock-create and one lock-delete API request per completed replay.
A failed Job leaves the migration state marker unchanged, but migrations may
have partially changed cluster resources. On timeout or lost Job status, the
script attempts foreground deletion and reports if it cannot confirm it.
Even confirmed deletion only proves that the Job stopped; it does not prove
which migrations ran. All three paths retain the lock for operator inspection.
A full replay advances `MIGRATIONS_APPLIED_THROUGH` only after the Job reports
success. Before creating a full apply Job, the helper rejects a target older
than that marker. It reads the marker again after success and patches it only
if the target is still current or later. The patch tests the ConfigMap's
resource version, so a concurrent state write makes the patch fail and keeps
the replay lock for inspection. Invalid marker values also stop a full replay.
This adds two ConfigMap reads per full apply; the JSON patch replaces the
previous merge patch. A dry-run or `--only` replay does not read or patch the
marker. Stubbed tests cover these control paths; they do not qualify the API
image, migration code, credentials or a live cluster.
The 0.272.0 prerequisite and postcondition add at most two read requests per
affected full or matching `--only` apply. Their runtime cost was not measured
separately; the live qualification records the total replay duration and node
resource samples.

If a process is interrupted, a Job fails, times out, or cannot be observed, or
the helper gets an uncertain error while creating the Job or patching the state
marker, its lock remains.
The API server may have accepted a request even when the client reports
failure, so these paths must not release the lock automatically.
Before clearing it, inspect `kubectl -n transpara get cm tinstaller-migrations-replay-lock -o yaml`
for the holder Job name and target, check that Job's terminal condition (or
confirm its absence or deletion), inspect available Job logs and the current
`tinstaller-state.MIGRATIONS_APPLIED_THROUGH` value, and confirm no helper
process is still running. A missing Job or unchanged marker does not prove
that no migration changed cluster resources. Check the affected resources and
decide whether a full replay, a targeted repair, or no replay is safe. Only
then delete the lock ConfigMap and retry if needed.
The Job-list and rollout checks reject observed unfinished upgrade Jobs and
incomplete API rollouts.
The published upgrade orchestrator does not use the helper's ConfigMap lock,
so an upgrade started after those checks can overlap replay. These two writers
cannot be made atomic by the helper alone. Restrict upgrade initiation for the
full replay window. This residual concurrency risk needs explicit Human
acceptance before production replay.

Published tInstaller 0.270.0–0.274.0 artifacts contain a default
deployment-read token in an operator-manifest URL that can appear in failed
fetch output. These helpers cannot change or revoke published artifacts.
The credential owner must rotate exposed values, publish a fixed installer,
and verify failed-fetch and upgrade logs with a synthetic canary; see
[tInstaller issue #54](https://github.com/transpara-ai/tinstaller/issues/54).

```bash
bash -n migration.sh fix-skipped-migrations.sh
shellcheck -s bash migration.sh fix-skipped-migrations.sh
python scripts/test-migration-helpers.py
```

## Revision History

| Version | Date | Change |
| --- | --- | --- |
| 0.1.0 | 2026-10-18 | First versioned edition; document migration replay safety, permissions and checks. |
| 0.1.1 | 2026-10-18 | Explain exact service-account inheritance and default-account behavior. |
| 0.1.2 | 2026-10-19 | Explain retained locks and operator checks after uncertain or partial migration execution. |
| 0.1.3 | 2026-10-19 | Explain compatibility with the published 0.274.0 runner, newer migration collections, and out-of-range selectors. |
| 0.1.4 | 2026-10-19 | Explain range and marker regression guards, concurrent state patch protection, and why the compatibility entry point stays standalone. |
| 0.1.5 | 2026-10-19 | Explain prerelease ordering in the version-window and marker guards. |
| 0.1.6 | 2026-10-19 | Reject zero-padded numeric versions, including prerelease and stored marker values. |
| 0.1.7 | 2026-10-20 | Document the missing CRD observed in a full pre-bridge upgrade and the helper's CRD prerequisite and custom-resource postcondition. |
| 0.1.8 | 2026-10-20 | Apply the MCP prerequisite and postcondition to matching module-scoped replays, while preserving unrelated targeted repairs. |
| 0.1.9 | 2026-10-20 | Preserve source Pod and container security contexts and runtime sandbox settings in replay Jobs. |
| 0.2.0 | 2026-10-20 | Add the Job deadline, API digest-convergence guard and scheduling constraints; record the upgrade race and published credential risk. |
| 0.2.1 | 2026-10-21 | Align the scheduling claim with Kind evidence and clarify selector validation and observed upgrade checks. |
| 0.2.2 | 2026-10-22 | Enforce the 0.274.0 SemVer bridge for real replays and test prerelease targets. |
