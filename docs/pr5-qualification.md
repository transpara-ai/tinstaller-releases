---
doc_id: TINSTALLER-RELEASES-PR5-QUALIFICATION
title: Migration replay helper qualification for PR 5
doc_type: qualification_report
status: draft
version: 0.2.0
created: 2026-10-20
updated: 2026-10-22
owner: Transpara AI
steward: Codex
project: tInstaller Releases
supersedes: []
canonical: false
---

# Migration replay helper qualification for PR 5

The helper code at `c1f8b9d` ran in one disposable Kind v1.35.0 cluster.
After commit `9e460fb` changed how the validated Deployment reaches Job
construction, that helper code ran in a second disposable Kind cluster.
Both clusters used the published tsystem-api 0.346.0 image pinned to digest
`sha256:24c22421ab985b600f0b5e232466639c65bea717876a41d566b960fa2d76d84a`
and the published tinstaller-migrations 0.274.0 image. Each fixture modeled a
ready post-upgrade API Deployment on a tainted node. It used a node selector,
node affinity, a toleration, a priority class, topology spread, nonroot
UID/GID 10001, `fsGroup` 10001, RuntimeDefault seccomp, a read-only root
filesystem, no privilege escalation, and dropped capabilities. The fixture
ServiceAccount had cluster-admin access only inside its disposable cluster.

At `c1f8b9d`, the 0.272.0 to 0.274.0 dry-run completed in about 11 seconds and
printed `PENDING []`. The Kubernetes API accepted the generated Job with
`activeDeadlineSeconds: 1200` and the source scheduling and security fields.
Both published-image containers exited successfully. The installer migration
marker remained at 0.272.0 and the helper removed its lock. When the API
Deployment was scaled to zero, a second dry-run stopped before Job creation;
the Job count remained one and no lock remained. Commit `9e460fb` then made
the validated Deployment read an explicit return value for Job construction.
Its 20 stubbed tests passed, including a Deployment that changes scheduling
settings between reads. A second Kind dry-run of that revision completed
with the same pinned runner image, 1200-second Job deadline, source node
selector and security context, unchanged marker, and no retained lock.
Both task-owned clusters, their exact Docker nodes and attached anonymous
volumes were deleted and verified absent. Their kubeconfigs were removed.

The earlier full-platform qualification found that a published 0.270.0 to
0.274.0 direct upgrade could finish its orchestrator Job 30–89 seconds before
all API Pods reached the target digest. A third full install with the target
MCP CRD pre-applied reached the expected MCP workload, route and Secret. The
current helper's digest guard closes the observed early-replay window when an
upgrade has already started, subject to the snapshot race below.

Together these Kind dry-runs verify Job admission, scheduling, and
published-image compatibility under the stated restrictions. The earlier
helper also rejected a zero-replica API Deployment in a live Kind cluster.

At PR head `765b37c`, a fourth task-owned Linode ran the published 0.270.0
installer into a full platform with API 0.338.0 and four available API Pods.
The target operator 0.15.1 MCP CRD was checked against SHA-256
`52c077b0591013248406c0d1793a05b9696d789650de266a639b2d9d046d0b66`,
applied, and observed `Established` before the direct 0.274.0 upgrade. The
upgrade selected nine image changes, completed migration 0.272.0 phase `post`,
created the MCP CR, and converged all four API Pods to the published 0.346.0
digest. Its Job completion was first observed about 71 seconds before the
target API Pod digest convergence; the helper ran only after convergence.
The same installed Envoy Gateway v1.1.2 parser warning required the previously
qualified disposable-run compatibility override.

The exact current helper's dry-run selected migration 0.272.0, left the
marker unchanged, and removed its lock. Its resource-changing replay then
completed the pre and post phases in a 73-second Job, advanced
`MIGRATIONS_APPLIED_THROUGH` to 0.274.0, and removed its lock. Readback showed
the MCP CR, one available MCP replica and ready endpoint, an accepted
`/ai/mcp` route with resolved references, the AI gateway route/configuration,
and a populated MCP authentication Secret. All four API Pods remained ready
on the target digest. With the API Deployment temporarily scaled to zero, the
same helper rejected another dry-run before Job creation; the Job count stayed
at two, no lock remained, and all four API replicas were restored and ready.
Both replay Jobs carried the 1200-second deadline and 24-hour terminal TTL.
The VM and firewall returned 404 on Linode readback, no volume was attached,
and the task SSH private key was removed. Filtered evidence is in the
owner-only `tinstaller-releases-pr5-current-head-20261022` campaign directory.

This qualification does not verify the 20-minute deadline firing or exclusion
of an upgrade initiated after the helper's snapshot checks. The published
upgrade orchestrator does not honor the replay lock, so production replay
still requires operational coordination or a separately released,
cooperative upgrade lock. The full replay used the installed platform's
security context; the stricter nonroot context was exercised in the Kind
dry-runs. Cluster load and dedicated-node scheduling latency were not
measured for the current-head full-platform run. The observed 73-second Job
duration is a disposable-node result, not a production capacity estimate.

Published installer credential removal and rotation are tracked in
[tInstaller issue #54](https://github.com/transpara-ai/tinstaller/issues/54).
The helper does not revoke a token embedded in older released artifacts.

## Revision History

| Version | Date | Change |
| --- | --- | --- |
| 0.1.0 | 2026-10-20 | Record full-platform observations, the first gate-fix helper dry-run and scheduling qualification, limits, and verified teardown. |
| 0.1.1 | 2026-10-20 | Record the repeated dry-run after making the validated Deployment read explicit and verify its teardown. |
| 0.1.2 | 2026-10-20 | Identify which helper revision ran in each Kind cluster and limit the live rejection claim to the earlier revision. |
| 0.2.0 | 2026-10-22 | Add current-head full-platform resource-changing replay, live zero-replica rejection, and provider-verified teardown; retain the upgrade-start race and deadline limits. |
