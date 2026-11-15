#!/bin/bash
# Re-run cluster migrations skipped by a direct pre-bridge (<0.274.0) -> post-bridge upgrade.
# Clones the tsystem-api Deployment pod's identity, env, volumes, security and
# scheduling settings into a one-off Job, mounts the
# TinstallerMigrationImage for the installed release, and runs pre+post migrations for
# (FROM, TO]. Mirrors what the upgrade orchestrator does with the load-migrations initContainer.
#
# Usage: bash migration.sh [--dry-run] [--only <module-substr>] [FROM=0.272.0] [TO=<INSTALLER_VERSION>]
#   --only enable_tcache_auth   replay matching modules (does not advance MIGRATIONS_APPLIED_THROUGH)
# --dry-run still creates a Kubernetes Job with the API deployment's service account,
# images, environment, and volumes; only the migration pre/post steps are skipped.
# The Job waits up to 20 minutes and has a 24-hour cleanup TTL. On timeout,
# foreground deletion is attempted. The replay lock remains when execution
# may have made partial changes, even if Job deletion succeeds.
set -euo pipefail
NS=${NS:-transpara}
DRY=0; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;;
  --only)
    if [ $# -lt 2 ] || [ -z "$2" ]; then
      echo "ERROR: --only needs a migration module substring." >&2; exit 2
    fi
    ONLY="$2"; shift 2;;
  *) break;;
esac; done
if [ $# -gt 2 ]; then echo "ERROR: expected at most FROM and TO." >&2; exit 2; fi
if [[ ! "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#NS}" -gt 63 ]; then
  echo "ERROR: NS must be a Kubernetes namespace name." >&2; exit 2
fi
if [ -n "$ONLY" ] && [[ ! "$ONLY" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
  echo "ERROR: --only must name a Python migration module substring." >&2; exit 2
fi
FROM=${1:-0.272.0}
TO=${2:-$(kubectl -n "$NS" get cm tinstaller-state -o jsonpath='{.data.INSTALLER_VERSION}')}
# The version becomes an image tag, a release URL component and a migration bound.
# Require SemVer numeric spelling, including prerelease identifiers: accepting
# "01" as equal to "1" can hide a later identifier and regress the state marker.
valid_version() {
  local LC_ALL=C
  local version=$1 identifier
  local -a identifiers
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?$ ]] || return 1
  [[ "$version" == *-* ]] || return 0
  IFS=. read -r -a identifiers <<< "${version#*-}"
  for identifier in "${identifiers[@]}"; do
    [[ "$identifier" =~ ^0[0-9]+$ ]] && return 1
  done
  return 0
}
# Compare numeric identifiers without machine-integer overflow. The version
# parser accepts long identifiers from release inputs but rejects leading zeroes.
number_lt() {
  local left=${1#"${1%%[!0]*}"} right=${2#"${2%%[!0]*}"}
  left=${left:-0}; right=${right:-0}
  if [ "${#left}" -ne "${#right}" ]; then
    [ "${#left}" -lt "${#right}" ]
  else
    [[ "$left" < "$right" ]]
  fi
}
# SemVer compares release components numerically. In a prerelease, numeric
# identifiers sort before text; otherwise identifiers compare as ASCII text.
# A shorter equal-prefix prerelease is earlier than a longer one, and any
# prerelease is earlier than the unqualified release.
ver_lt() {
  local LC_ALL=C
  local left_core=${1%%-*} right_core=${2%%-*}
  local -a left_parts right_parts
  local i left_id right_id
  IFS=. read -r -a left_parts <<< "$left_core"
  IFS=. read -r -a right_parts <<< "$right_core"
  for i in 0 1 2; do
    if number_lt "${left_parts[i]}" "${right_parts[i]}"; then return 0; fi
    if number_lt "${right_parts[i]}" "${left_parts[i]}"; then return 1; fi
  done
  if [ "$1" = "$left_core" ]; then return 1; fi
  if [ "$2" = "$right_core" ]; then return 0; fi
  IFS=. read -r -a left_parts <<< "${1#*-}"
  IFS=. read -r -a right_parts <<< "${2#*-}"
  for ((i=0; i<${#left_parts[@]} && i<${#right_parts[@]}; i++)); do
    left_id=${left_parts[i]}; right_id=${right_parts[i]}
    if [ "$left_id" = "$right_id" ]; then continue; fi
    if [[ "$left_id" =~ ^[0-9]+$ ]]; then
      if [[ "$right_id" =~ ^[0-9]+$ ]]; then
        number_lt "$left_id" "$right_id"; return
      fi
      return 0
    fi
    if [[ "$right_id" =~ ^[0-9]+$ ]]; then return 1; fi
    [[ "$left_id" < "$right_id" ]]; return
  done
  [ "${#left_parts[@]}" -lt "${#right_parts[@]}" ]
}
if [ -z "${2:-}" ] && valid_version "$TO" && ver_lt "$TO" 0.274.0; then
  # Upgrade still in flight (INSTALLER_VERSION not advanced yet): take the target from its payload.
  CM=$(kubectl -n "$NS" get cm -l app=tsystem-upgrade --sort-by=.metadata.creationTimestamp -o name | tail -1)
  [ -n "$CM" ] && TO=$(kubectl -n "$NS" get "$CM" -o jsonpath='{.data.payload\.json}' | jq -r '.request.target_version // .available_versions.tinstaller.version')
fi
if ! valid_version "$FROM" || ! valid_version "$TO"; then
  echo "ERROR: FROM and TO must be safe release versions." >&2; exit 2
fi
if ! ver_lt "$FROM" "$TO"; then
  echo "ERROR: FROM must be earlier than TO ($FROM >= $TO)." >&2; exit 2
fi
# A replay that selects the 0.272.0 MCP module needs its CRD. The published
# migration loader sets __module__ to the manifest's module name; --only
# matches a substring of that name. Use the same name here so an unrelated
# targeted repair keeps its independent path.
# The direct pre-bridge upgrade can update the operator image without the
# CRD, so reject the MCP replay before it creates a Job or restarts tauth.
# Other migration effects may already exist and must not be rolled back.
NEEDS_MCP_CR=0
MCP_MODULE=m_0_272_0_install_transpara_mcp
if [ "$DRY" = 0 ] && ver_lt "$FROM" 0.272.0 &&
   ! ver_lt "$TO" 0.272.0 &&
   { [ -z "$ONLY" ] || [[ "$MCP_MODULE" == *"$ONLY"* ]]; }; then
  NEEDS_MCP_CR=1
  if ! kubectl get crd transparamcps.charts.transpara.com -o name >/dev/null 2>&1; then
    echo "ERROR: the 0.272.0 migration needs CRD transparamcps.charts.transpara.com; install the target operator CRDs before replay." >&2
    exit 1
  fi
fi
check_marker_not_ahead() {
  local marker
  if ! marker=$(jq -r '.data | if type == "object" then (.MIGRATIONS_APPLIED_THROUGH // "") else error("missing data") end' <<< "$1"); then
    echo "ERROR: cannot read tinstaller-state migration marker; inspect it before replay." >&2
    return 1
  fi
  if [ -n "$marker" ] && ! valid_version "$marker"; then
    echo "ERROR: tinstaller-state has an invalid MIGRATIONS_APPLIED_THROUGH value; inspect it before replay." >&2
    return 1
  fi
  if [ -n "$marker" ] && ver_lt "$TO" "$marker"; then
    echo "ERROR: TO=$TO would regress MIGRATIONS_APPLIED_THROUGH=$marker; inspect state before replay." >&2
    return 1
  fi
}
# A full apply changes this marker. Reject an older target before creating a
# Job; a second check after success catches changes made while the Job ran.
if [ "$DRY" = 0 ] && [ -z "$ONLY" ]; then
  STATE=$(kubectl -n "$NS" get cm tinstaller-state -o json)
  check_marker_not_ahead "$STATE" || exit 1
fi
DEPLOY=$(kubectl -n "$NS" get deploy tsystem-api -o json)
API_IMG=$(jq -er '.spec.template.spec.containers[0].image | strings' <<< "$DEPLOY")
REPO=${API_IMG%%/tsystem-api*}
if [ "$REPO" = "$API_IMG" ]; then
  echo "ERROR: tsystem-api image does not identify a migrations registry." >&2; exit 1
fi
MIG_IMG="$REPO/tinstaller-migrations:$TO"
JOB=migrations-replay-$(date +%s)-$$
# SemVer orders every prerelease below its base release. Block real replays
# until the target reaches the bridge; dry-runs can still inspect prerelease tags.
if [ "$DRY" = 0 ] && ver_lt "$TO" 0.274.0; then
  echo "ERROR: installed version is $TO; nothing to replay (needs >= 0.274.0). Is an upgrade still running?" >&2; exit 1
fi
# A Job can be nonterminal with zero active Pods before creation or between
# retries. Block until Kubernetes records a Complete or Failed condition.
# Full and module-scoped replays must not race an upgrade or another replay.
JOBS=$(kubectl -n "$NS" get jobs -l 'app in (tsystem-upgrade,migrations-replay)' -o json)
NONTERMINAL=$(jq -r 'if (.items | type) != "array" then true else any(.items[]; ([.status.conditions[]? | select((.type == "Complete" or .type == "Failed") and .status == "True")] | length) == 0) end' <<< "$JOBS")
if [ "$NONTERMINAL" = true ]; then
  echo "ERROR: an upgrade or replay Job is unfinished in $NS; wait for a terminal Job condition." >&2; exit 1
fi
# Kubernetes creates a named ConfigMap atomically. A second replay cannot pass
# this guard while the first owns it, even if both saw an empty Job list above.
# Do not remove an uncertain lock automatically: an interrupted Job could still
# be running. The README gives the inspection procedure for stale locks.
LOCK=tinstaller-migrations-replay-lock
if ! kubectl -n "$NS" create configmap "$LOCK" --from-literal="holder=$JOB" --from-literal="target=$TO"; then
  echo "ERROR: replay lock $LOCK exists or could not be created in $NS; inspect it before retry." >&2
  exit 1
fi
release_lock() {
  if ! kubectl -n "$NS" delete configmap "$LOCK" --wait=true; then
    echo "ERROR: could not release replay lock $LOCK in $NS; inspect it before retry." >&2
    return 1
  fi
}
# A terminal upgrade Job can precede Deployment convergence. Require every
# selected API Pod to be Ready on the desired immutable image before replay.
# Return the validated Deployment JSON so Job construction uses the exact
# source that passed these checks. This is a snapshot guard; an upgrade started
# afterward still needs coordination because its orchestrator does not share lock.
check_api_rollout() {
  local deploy desired digest container replicas selector pods
  if ! deploy=$(kubectl -n "$NS" get deploy tsystem-api -o json); then
    echo "ERROR: cannot read the API Deployment before replay." >&2; return 1
  fi
  desired=$(jq -er '.spec.template.spec.containers[0].image | strings' <<< "$deploy") || return 1
  if [ "$desired" != "$API_IMG" ] || [[ ! "$desired" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: API image changed or lacks a pinned sha256 digest; inspect rollout before replay." >&2; return 1
  fi
  digest=${desired##*@}
  container=$(jq -er '.spec.template.spec.containers[0].name | strings' <<< "$deploy") || return 1
  replicas=$(jq -er '.spec.replicas // 1' <<< "$deploy") || return 1
  if ! jq -e --argjson replicas "$replicas" '
    .metadata.generation as $generation |
    .status.observedGeneration as $observed |
    ($replicas > 0 and $observed >= $generation and
     .status.updatedReplicas == $replicas and
     .status.readyReplicas == $replicas and
     .status.availableReplicas == $replicas)' <<< "$deploy" >/dev/null; then
    echo "ERROR: API Deployment has not converged to its desired replicas." >&2; return 1
  fi
  # Reject unsupported selector forms instead of inspecting the wrong Pods.
  selector=$(jq -er '
    .spec.selector as $s |
    if (($s.matchExpressions // []) | length) > 0 or
       (($s.matchLabels // {}) | length) == 0 then error("unsupported selector")
    else $s.matchLabels | to_entries | sort_by(.key) |
      map("\(.key)=\(.value)") | join(",") end' <<< "$deploy") || {
    echo "ERROR: API Deployment needs a nonempty matchLabels selector for replay." >&2; return 1
  }
  if ! pods=$(kubectl -n "$NS" get pods -l "$selector" -o json); then
    echo "ERROR: cannot read API Pods before replay." >&2; return 1
  fi
  if ! jq -e --arg image "$desired" --arg digest "$digest" \
      --arg container "$container" --argjson replicas "$replicas" '
    (.items | type) == "array" and (.items | length) == $replicas and
    all(.items[];
      .metadata.deletionTimestamp == null and
      (.spec.containers | any(.name == $container and .image == $image)) and
      (.status.conditions // [] | any(.type == "Ready" and .status == "True")) and
      (.status.containerStatuses // [] | any(
        .name == $container and .ready == true and
        (.imageID | strings | endswith("@" + $digest)))))' <<< "$pods" >/dev/null; then
    echo "ERROR: API Pods are not all Ready on the desired image digest." >&2; return 1
  fi
  printf '%s\n' "$deploy"
}
if ! DEPLOY=$(check_api_rollout); then
  release_lock
  exit 1
fi
echo "FROM=$FROM TO=$TO DRY_RUN=$DRY ONLY=${ONLY:-<all>}"
echo "runner image:     $API_IMG"
echo "migrations image: $MIG_IMG"

PY=$(cat <<'PY'
import json, sys, yaml, httpx
from kubernetes import config
config.load_incluster_config()
from app.upgrade.migrations.runner import ClusterMigrationRunner
# Arguments are separate Job command elements, never shell-substituted into code.
FROM, TO, NS, DRY, ONLY = sys.argv[1:6]
DRY = DRY == "1"
r = ClusterMigrationRunner(); r.load("/shared/migrations")
if ONLY:
    # The 0.274.0 runner uses an OrderedDict; newer runners use a list so
    # multiple modules can share a version. Preserve its storage type and order.
    pairs = r.migrations.items() if isinstance(r.migrations, dict) else r.migrations
    r.migrations = type(r.migrations)(
        (v, m) for v, m in pairs if ONLY in type(m).__module__
    )
    if not r.migrations: sys.exit(f"no migration module matches {ONLY!r}")
# pending_versions was added after the 0.274.0 API image. Both known runners
# use _pending for execution, so its version window is the fallback here.
pending = (r.pending_versions(FROM, TO) if hasattr(r, "pending_versions")
           else [v for v, _ in r._pending(FROM, TO)])
if ONLY and not pending:
    sys.exit(f"no migration module matching {ONLY!r} is pending in ({FROM}, {TO}]")
print("PENDING", json.dumps(pending), flush=True)
if DRY: sys.exit(0)
url = f"https://github.com/transpara/tinstaller-releases/releases/download/{TO}/versions.yaml"
response = httpx.get(url, follow_redirects=True, timeout=30)
response.raise_for_status()
raw = yaml.safe_load(response.text)
ctx = {"_raw": raw}
r.run_pre_upgrade(FROM, TO, NS, None, context=ctx); print("PRE_DONE", flush=True)
r.run_post_upgrade(FROM, TO, NS, None, context=ctx); print("POST_DONE", flush=True)
PY
)

# The $names below are jq variables bound by --arg, not shell expansions.
# shellcheck disable=SC2016
jq \
  --arg ns "$NS" --arg job "$JOB" --arg mig "$MIG_IMG" --arg py "$PY" \
  --arg from "$FROM" --arg to "$TO" --arg dry "$DRY" --arg only "$ONLY" '
  .spec.template.spec as $p | ($p.containers[0]) as $c | {
  apiVersion: "batch/v1", kind: "Job",
  metadata: {name: $job, namespace: $ns, labels: {app: "migrations-replay"}},
  # The API server stops a stranded Job after 20 minutes even if the invoking
  # shell exits. TTL cleans only terminal Jobs; it is not a runtime limit.
  spec: {backoffLimit: 0, activeDeadlineSeconds: 1200,
    ttlSecondsAfterFinished: 86400, template: {spec: {
    # Omission means Kubernetes uses the namespace default account, just as
    # it does for the source Deployment; never elevate the replay Job.
    serviceAccountName: $p.serviceAccountName,
    # Preserve an explicit false: omitting it could mount a token that the
    # source Deployment deliberately suppressed.
    automountServiceAccountToken: $p.automountServiceAccountToken,
    # Keep source Pod user/group, seccomp and sandbox settings. The Job
    # carries its credentials and volumes, so dropping these restrictions
    # would execute the same migration under a weaker runtime boundary.
    securityContext: $p.securityContext,
    runtimeClassName: $p.runtimeClassName,
    hostUsers: $p.hostUsers,
    # A dedicated or tainted API node may be the only place its credentials,
    # mounts and network dependencies work. Keep its scheduling requirements.
    nodeSelector: $p.nodeSelector,
    tolerations: $p.tolerations,
    affinity: $p.affinity,
    priorityClassName: $p.priorityClassName,
    schedulerName: $p.schedulerName,
    topologySpreadConstraints: $p.topologySpreadConstraints,
    restartPolicy: "Never",
    imagePullSecrets: ($p.imagePullSecrets // []),
    volumes: (($p.volumes // []) + [{name: "migrations", emptyDir: {}}]),
    initContainers: (($p.initContainers // []) + [{
      name: "load-migrations", image: $mig,
      command: ["sh", "-c", "cp -a /migrations/. /shared/migrations/"],
      securityContext: $c.securityContext,
      volumeMounts: [{name: "migrations", mountPath: "/shared/migrations"}]}]),
    containers: [{
      name: "migrate", image: $c.image,
      command: ["python", "-c", $py, $from, $to, $ns, $dry, $only],
      securityContext: $c.securityContext,
      env: ($c.env // []), envFrom: ($c.envFrom // []),
      volumeMounts: (($c.volumeMounts // []) + [{name: "migrations", mountPath: "/shared/migrations"}])}]
  }}}}
  # Drop omitted fields at this Pod-spec level; retain false, zero and empty values.
  | .spec.template.spec |= with_entries(select(.value != null))
  | if .spec.template.spec.initContainers[-1].securityContext == null
    then del(.spec.template.spec.initContainers[-1].securityContext) else . end
  | if .spec.template.spec.containers[0].securityContext == null
    then del(.spec.template.spec.containers[0].securityContext) else . end' <<< "$DEPLOY" | kubectl -n "$NS" apply -f -

echo "waiting for job/$JOB ..."
# A failed, unobservable, or timed-out Job may already have changed the cluster.
# Stop an unobservable or timed-out Job, but keep the lock after deletion: that
# confirms only that it stopped, not which migrations ran. Operators must inspect
# the state and effects before deciding whether any replay is safe.
stop_replay_job() {
  if ! kubectl -n "$NS" delete job "$JOB" --cascade=foreground --wait=true --timeout=60s; then
    echo "ERROR: could not confirm deletion of job/$JOB in $NS; inspect it before retry." >&2
    return 1
  fi
}
RESULT=""
SUCCEEDED=0
FAILED=0
for i in $(seq 1 240); do
  if ! OBSERVED=$(kubectl -n "$NS" get job "$JOB" -o json |
    jq -r '[.status.succeeded // 0, .status.failed // 0] | @tsv'); then
    echo "ERROR: lost job/$JOB status in $NS; migration effects are uncertain." >&2
    stop_replay_job || true
    echo "ERROR: replay lock $LOCK remains for operator inspection before retry." >&2
    exit 1
  fi
  read -r SUCCEEDED FAILED <<< "$OBSERVED"
  if [ "$SUCCEEDED" -ge 1 ]; then RESULT=success; break; fi
  if [ "$FAILED" -ge 1 ]; then RESULT=failed; break; fi
  if [ "$i" -lt 240 ]; then sleep 5; fi
done
kubectl -n "$NS" logs "job/$JOB" -c migrate --tail=-1 ||
  echo "WARN: job/$JOB logs could not be read; Job status remains authoritative." >&2
echo "Job result: succeeded=$SUCCEEDED failed=$FAILED"
case "$RESULT" in
  success) ;;
  failed) echo "ERROR: migration replay Job failed; state was not advanced and effects may be partial." >&2
          echo "ERROR: replay lock $LOCK remains for operator inspection before retry." >&2
          exit 1;;
  *) echo "ERROR: migration replay Job timed out; stopping it. Migration effects are uncertain." >&2
     stop_replay_job || true
     echo "ERROR: replay lock $LOCK remains for operator inspection before retry." >&2
     exit 1;;
esac
# Older API upgrade runners can mark the 0.272.0 migration complete even if
# its TransparaMcp create failed. A successful full or matching --only replay
# must leave the CR present before this helper reports success or advances its
# independent installer marker.
if [ "$NEEDS_MCP_CR" = 1 ] &&
   ! kubectl -n "$NS" get transparamcps.charts.transpara.com transpara-mcp -o name >/dev/null 2>&1; then
  echo "ERROR: replay Job succeeded but TransparaMcp CR transpara-mcp is absent; replay lock remains for inspection." >&2
  exit 1
fi
if [ "$DRY" = 0 ] && [ -z "$ONLY" ]; then
  STATE=$(kubectl -n "$NS" get cm tinstaller-state -o json)
  if ! check_marker_not_ahead "$STATE"; then
    echo "ERROR: replay lock $LOCK remains for operator inspection before retry." >&2
    exit 1
  fi
  RV=$(jq -r '.metadata.resourceVersion // ""' <<< "$STATE")
  if [ -z "$RV" ]; then
    echo "ERROR: tinstaller-state has no resourceVersion; replay lock remains for inspection." >&2
    exit 1
  fi
  # The resourceVersion test makes a concurrent ConfigMap write fail instead
  # of replacing a newer marker. The lock remains if the patch is uncertain.
  # $rv and $to are jq variables bound by --arg, not shell expansions.
  # shellcheck disable=SC2016
  PATCH=$(jq -nc --arg rv "$RV" --arg to "$TO" \
    '[{"op":"test","path":"/metadata/resourceVersion","value":$rv},
      {"op":"add","path":"/data/MIGRATIONS_APPLIED_THROUGH","value":$to}]')
  kubectl -n "$NS" patch cm tinstaller-state --type json -p "$PATCH"
  echo "tinstaller-state MIGRATIONS_APPLIED_THROUGH=$TO"
fi
release_lock
