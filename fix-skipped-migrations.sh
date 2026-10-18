#!/bin/bash
# Compatibility entry point; keep its safety checks aligned with migration.sh.
# This copy stays standalone for callers that pipe this historical script to bash.
# Re-run cluster migrations skipped by a direct pre-bridge (<0.274.0) -> post-bridge upgrade.
# Clones the tsystem-api Deployment pod (service account, env, volumes) into a one-off Job, mounts the
# TinstallerMigrationImage for the installed release, and runs pre+post migrations for
# (FROM, TO]. Mirrors what the upgrade orchestrator does with the load-migrations initContainer.
#
# Usage: bash fix-skipped-migrations.sh [--dry-run] [--only <module-substr>] [FROM=0.272.0] [TO=<INSTALLER_VERSION>]
#   --only enable_tcache_auth   replay matching modules (does not advance MIGRATIONS_APPLIED_THROUGH)
# --dry-run still creates a Kubernetes Job with the API deployment's service account,
# images, environment, and volumes; only the migration pre/post steps are skipped.
# The Job waits up to 20 minutes and has a 24-hour cleanup TTL. On timeout,
# foreground deletion is attempted; failure to confirm deletion is reported.
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
# Reject other text before it reaches any of those resources.
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; }
ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
if [ -z "${2:-}" ] && valid_version "$TO" && ver_lt "${TO%%-*}" 0.274.0; then
  # Upgrade still in flight (INSTALLER_VERSION not advanced yet): take the target from its payload.
  CM=$(kubectl -n "$NS" get cm -l app=tsystem-upgrade --sort-by=.metadata.creationTimestamp -o name | tail -1)
  [ -n "$CM" ] && TO=$(kubectl -n "$NS" get "$CM" -o jsonpath='{.data.payload\.json}' | jq -r '.request.target_version // .available_versions.tinstaller.version')
fi
if ! valid_version "$FROM" || ! valid_version "$TO"; then
  echo "ERROR: FROM and TO must be safe release versions." >&2; exit 2
fi
API_IMG=$(kubectl -n "$NS" get deploy tsystem-api -o jsonpath='{.spec.template.spec.containers[0].image}')
REPO=${API_IMG%%/tsystem-api*}
if [ "$REPO" = "$API_IMG" ]; then
  echo "ERROR: tsystem-api image does not identify a migrations registry." >&2; exit 1
fi
MIG_IMG="$REPO/tinstaller-migrations:$TO"
JOB=migrations-replay-$(date +%s)-$$
if ver_lt "${TO%%-*}" 0.274.0; then
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
    r.migrations = [(v, m) for v, m in r.migrations if ONLY in type(m).__module__]
    if not r.migrations: sys.exit(f"no migration module matches {ONLY!r}")
pending = r.pending_versions(FROM, TO)
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

kubectl -n "$NS" get deploy tsystem-api -o json | jq \
  --arg ns "$NS" --arg job "$JOB" --arg mig "$MIG_IMG" --arg py "$PY" \
  --arg from "$FROM" --arg to "$TO" --arg dry "$DRY" --arg only "$ONLY" '
  .spec.template.spec as $p | ($p.containers[0]) as $c | {
  apiVersion: "batch/v1", kind: "Job",
  metadata: {name: $job, namespace: $ns, labels: {app: "migrations-replay"}},
  spec: {backoffLimit: 0, ttlSecondsAfterFinished: 86400, template: {spec: {
    serviceAccountName: ($p.serviceAccountName // "tsystem-api"),
    restartPolicy: "Never",
    imagePullSecrets: ($p.imagePullSecrets // []),
    volumes: (($p.volumes // []) + [{name: "migrations", emptyDir: {}}]),
    initContainers: (($p.initContainers // []) + [{
      name: "load-migrations", image: $mig,
      command: ["sh", "-c", "cp -a /migrations/. /shared/migrations/"],
      volumeMounts: [{name: "migrations", mountPath: "/shared/migrations"}]}]),
    containers: [{
      name: "migrate", image: $c.image,
      command: ["python", "-c", $py, $from, $to, $ns, $dry, $only],
      env: ($c.env // []), envFrom: ($c.envFrom // []),
      volumeMounts: (($c.volumeMounts // []) + [{name: "migrations", mountPath: "/shared/migrations"}])}]
  }}}}' | kubectl -n "$NS" apply -f -

echo "waiting for job/$JOB ..."
# A failed or unobservable Job must not be reported as a completed repair.
# A timed-out Job gets foreground deletion; failed deletion needs operator inspection.
stop_replay_job() {
  if ! kubectl -n "$NS" delete job "$JOB" --cascade=foreground --wait=true --timeout=60s; then
    echo "ERROR: could not confirm deletion of job/$JOB in $NS; inspect it before retry." >&2
  fi
}
RESULT=""
SUCCEEDED=0
FAILED=0
for i in $(seq 1 240); do
  if ! OBSERVED=$(kubectl -n "$NS" get job "$JOB" -o json |
    jq -r '[.status.succeeded // 0, .status.failed // 0] | @tsv'); then
    echo "ERROR: lost job/$JOB status in $NS." >&2
    stop_replay_job
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
  failed) echo "ERROR: migration replay Job failed; state was not advanced." >&2; exit 1;;
  *) echo "ERROR: migration replay Job timed out; stopping it." >&2
     stop_replay_job
     exit 1;;
esac
if [ "$DRY" = 0 ] && [ -z "$ONLY" ]; then
  PATCH=$(jq -nc --arg to "$TO" '{data: {MIGRATIONS_APPLIED_THROUGH: $to}}')
  kubectl -n "$NS" patch cm tinstaller-state --type merge -p "$PATCH"
  echo "tinstaller-state MIGRATIONS_APPLIED_THROUGH=$TO"
fi
