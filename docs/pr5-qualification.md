---
doc_id: TINSTALLER-RELEASES-PR5-QUALIFICATION
title: Migration replay helper qualification for PR 5
doc_type: qualification_report
status: draft
version: 0.1.0
created: 2026-10-20
updated: 2026-10-20
owner: Transpara AI
steward: Codex
project: tInstaller Releases
supersedes: []
canonical: false
---

# Migration replay helper qualification for PR 5

The helper ran in a disposable Kind v1.35.0 cluster with the published
tsystem-api 0.346.0 image pinned to digest
`sha256:24c22421ab985b600f0b5e232466639c65bea717876a41d566b960fa2d76d84a`
and the published tinstaller-migrations 0.274.0 image. The fixture modeled a
ready post-upgrade API Deployment on a tainted node. It used a node selector,
node affinity, a toleration, a priority class, topology spread, nonroot
UID/GID 10001, `fsGroup` 10001, RuntimeDefault seccomp, a read-only root
filesystem, no privilege escalation, and dropped capabilities. The fixture
ServiceAccount had cluster-admin access only inside this disposable cluster.

The helper's 0.272.0 to 0.274.0 dry-run completed in about 11 seconds and
printed `PENDING []`. The Kubernetes API accepted the generated Job with
`activeDeadlineSeconds: 1200` and the source scheduling and security fields.
Both published-image containers exited successfully. The installer migration
marker remained at 0.272.0 and the helper removed its lock. When the API
Deployment was scaled to zero, a second dry-run stopped before Job creation;
the Job count remained one and no lock remained. The task-owned cluster, exact
Docker node and attached anonymous volume were then deleted and verified
absent. The disposable kubeconfig was removed.

The earlier full-platform qualification found that a published 0.270.0 to
0.274.0 direct upgrade could finish its orchestrator Job 30–89 seconds before
all API Pods reached the target digest. A third full install with the target
MCP CRD pre-applied reached the expected MCP workload, route and Secret. The
current helper's digest guard closes the observed early-replay window when an
upgrade has already started, subject to the snapshot race below.

This Kind dry-run verifies Job admission, scheduling, published-image
compatibility under the stated restrictions, and a rollout rejection. It does
not verify a resource-changing replay on a full installed platform, the
20-minute deadline firing, or exclusion of an upgrade initiated after the
helper's snapshot checks. The published upgrade orchestrator does not honor
the replay lock, so production replay still requires operational coordination
or a separately released, cooperative upgrade lock. Cluster load and
dedicated-node scheduling latency were not measured beyond this fixture.

Published installer credential removal and rotation are tracked in
[tInstaller issue #54](https://github.com/transpara-ai/tinstaller/issues/54).
The helper does not revoke a token embedded in older released artifacts.

## Revision History

| Version | Date | Change |
| --- | --- | --- |
| 0.1.0 | 2026-10-20 | Record full-platform observations, live final-helper dry-run and scheduling qualification, limits, and verified teardown. |
