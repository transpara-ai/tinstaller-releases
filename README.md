---
doc_id: TINSTALLER-RELEASES-README
title: tInstaller releases quickstart and migration repair
doc_type: readme
status: draft
version: 0.1.1
created: 2025-08-13
updated: 2026-10-18
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

`--dry-run` does not invoke the pre- or post-upgrade migrations, but it still
creates a Kubernetes Job using the API deployment's service account, images,
environment and volumes to list pending migrations. The Job can run for up to
20 minutes and has a 24-hour cleanup TTL. Running either command changes the
cluster and requires separate operational authorization. `--only <module-substr>`
replays matching migration modules and does not advance `MIGRATIONS_APPLIED_THROUGH`.

`fix-skipped-migrations.sh` remains available as a standalone compatibility
entry point; prefer `migration.sh` for new use. Both scripts reject malformed
versions and module selectors, stop if an upgrade or another replay Job lacks
a terminal Complete or Failed condition (including gaps between Pod retries),
and create an atomic `tinstaller-migrations-replay-lock` ConfigMap before
starting a replay Job. The lock prevents two helper invocations from starting
concurrent Jobs. The operator running either helper needs namespace access to:

- get the `tsystem-api` Deployment;
- get and list ConfigMaps, create/delete the replay-lock ConfigMap, and patch
  `tinstaller-state` (the upgrade-record lookup also lists ConfigMaps);
- get/list/create/patch/delete Jobs, and watch Jobs and ConfigMaps while
  foreground deletion or lock cleanup completes; and
- get/list Pods and get Pod logs for `kubectl logs job/<name>`.

The replay Job uses the API Deployment's service-account identity and needs its
own migration permissions. A named account is copied exactly. If the Deployment
omits `serviceAccountName`, the Job omits it too and Kubernetes selects the
namespace's `default` account; the helper never substitutes a more privileged
account. The helper does not grant either identity access.
This adds one create and one delete API request per completed replay. A failed
Job leaves the migration state unchanged. On timeout or lost Job status, the
script attempts foreground deletion and reports if it cannot confirm it. A
full replay advances `MIGRATIONS_APPLIED_THROUGH` only after the Job reports
success. Stubbed tests
cover these control paths; they do not qualify the API image, migration code,
credentials or a live cluster.

If a process is interrupted, cannot confirm Job deletion, or gets an uncertain
error while creating the Job or patching the state marker, its lock remains.
The API server may have accepted a request even when the client reports
failure, so these paths must not release the lock automatically.
Before clearing it, inspect `kubectl -n transpara get cm tinstaller-migrations-replay-lock -o yaml`
for the holder Job name and target, check that Job's terminal condition (or
confirm its absence or deletion), inspect the current
`tinstaller-state.MIGRATIONS_APPLIED_THROUGH` value, and confirm no helper
process is still running. Only then delete the lock ConfigMap and retry.
The Job-list check still protects against
an upgrade that was already underway; upgrades started after that check require
operational coordination.

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
