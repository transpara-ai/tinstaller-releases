#!/bin/bash
# Re-run cluster migrations skipped by a direct pre-bridge (<0.274.0) -> post-bridge upgrade.
# Clones the tsystem-api Deployment pod (SA, env, volumes) into a one-off Job, mounts the
# TinstallerMigrationImage for the installed release, and runs pre+post migrations for
# (FROM, TO]. Mirrors what the upgrade orchestrator does with the load-migrations initContainer.
#
# Usage: curl -sfL https://raw.githubusercontent.com/transpara/tinstaller-releases/main/migration.sh | bash -s -- [--dry-run] [--only <module-substr>] [FROM=0.272.0] [TO=<INSTALLER_VERSION>]
#   --only enable_tcache_auth   replay just that migration (does not advance MIGRATIONS_APPLIED_THROUGH)
# --dry-run still creates a Kubernetes Job with the API deployment's service account,
# images, environment, and volumes; only the migration pre/post steps are skipped.
# The Job waits up to 20 minutes and has a 24-hour cleanup TTL.
set -euo pipefail
NS=${NS:-transpara}
DRY=0; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY=1; shift;;
  --only) ONLY="$2"; shift 2;;
  *) break;;
esac; done
FROM=${1:-0.272.0}
TO=${2:-$(kubectl -n $NS get cm tinstaller-state -o jsonpath='{.data.INSTALLER_VERSION}')}
ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
if [ -z "${2:-}" ] && ver_lt "${TO%%-*}" 0.274.0; then
  # Upgrade still in flight (INSTALLER_VERSION not advanced yet): take the target from its payload.
  CM=$(kubectl -n $NS get cm -l app=tsystem-upgrade --sort-by=.metadata.creationTimestamp -o name | tail -1)
  [ -n "$CM" ] && TO=$(kubectl -n $NS get $CM -o jsonpath='{.data.payload\.json}' | jq -r '.request.target_version // .available_versions.tinstaller.version')
fi
API_IMG=$(kubectl -n $NS get deploy tsystem-api -o jsonpath='{.spec.template.spec.containers[0].image}')
REPO=${API_IMG%%/tsystem-api*}
MIG_IMG="$REPO/tinstaller-migrations:$TO"
JOB=migrations-replay-$(date +%s)
if ver_lt "${TO%%-*}" 0.274.0; then
  echo "ERROR: installed version is $TO; nothing to replay (needs >= 0.274.0). Is an upgrade still running?" >&2; exit 1
fi
if [ -z "$ONLY" ] && kubectl -n $NS get jobs -l app=tsystem-upgrade -o jsonpath='{range .items[*]}{.status.active}{"\n"}{end}' | grep -q 1; then
  echo "ERROR: an upgrade Job is still running in $NS; wait for it to finish." >&2; exit 1
fi
echo "FROM=$FROM TO=$TO DRY_RUN=$DRY ONLY=${ONLY:-<all>}"
echo "runner image:     $API_IMG"
echo "migrations image: $MIG_IMG"

PY=$(cat <<EOF
import json, sys, yaml, httpx
from kubernetes import config
config.load_incluster_config()
from app.upgrade.migrations.runner import ClusterMigrationRunner
FROM, TO, NS, DRY, ONLY = "$FROM", "$TO", "$NS", $DRY, "$ONLY"
r = ClusterMigrationRunner(); r.load("/shared/migrations")
if ONLY:
    r.migrations = [(v, m) for v, m in r.migrations if ONLY in type(m).__module__]
    if not r.migrations: sys.exit(f"no migration module matches {ONLY!r}")
pending = r.pending_versions(FROM, TO)
print("PENDING", json.dumps(pending), flush=True)
if DRY: sys.exit(0)
url = f"https://github.com/transpara/tinstaller-releases/releases/download/{TO}/versions.yaml"
raw = yaml.safe_load(httpx.get(url, follow_redirects=True, timeout=30).text)
ctx = {"_raw": raw}
r.run_pre_upgrade(FROM, TO, NS, None, context=ctx); print("PRE_DONE", flush=True)
r.run_post_upgrade(FROM, TO, NS, None, context=ctx); print("POST_DONE", flush=True)
EOF
)

kubectl -n $NS get deploy tsystem-api -o json | jq --arg ns "$NS" --arg job "$JOB" --arg mig "$MIG_IMG" --arg py "$PY" '
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
      command: ["python", "-c", $py],
      env: ($c.env // []), envFrom: ($c.envFrom // []),
      volumeMounts: (($c.volumeMounts // []) + [{name: "migrations", mountPath: "/shared/migrations"}])}]
  }}}}' | kubectl -n $NS apply -f -

echo "waiting for job/$JOB ..."
for i in $(seq 1 240); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}{.status.failed}')
  [ -n "$S" ] && break; sleep 5
done
kubectl -n $NS logs job/$JOB -c migrate --tail=-1
kubectl -n $NS get job $JOB -o jsonpath='{"\nJob result: succeeded="}{.status.succeeded}{" failed="}{.status.failed}{"\n"}'
if [ $DRY = 0 ] && [ -z "$ONLY" ] && [ "$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}')" = 1 ]; then
  kubectl -n $NS patch cm tinstaller-state --type merge -p "{\"data\":{\"MIGRATIONS_APPLIED_THROUGH\":\"$TO\"}}"
  echo "tinstaller-state MIGRATIONS_APPLIED_THROUGH=$TO"
fi
