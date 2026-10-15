#!/bin/bash
# Re-run cluster migrations skipped by a direct pre-bridge (<0.274.0) -> post-bridge upgrade.
# Clones the tsystem-api Deployment pod (SA, env, volumes) into a one-off Job, mounts the
# TinstallerMigrationImage for the installed release, and runs pre+post migrations for
# (FROM, TO]. Mirrors what the upgrade orchestrator does with the load-migrations initContainer.
#
# Usage: curl -sfL https://raw.githubusercontent.com/transpara/tinstaller-releases/main/fix-skipped-migrations.sh | bash -s -- [--dry-run] [FROM=0.272.0] [TO=<INSTALLER_VERSION>]
# --dry-run still creates a Kubernetes Job with the API deployment's service account,
# images, environment, and volumes; only the migration pre/post steps are skipped.
# The Job waits up to 20 minutes and has a 24-hour cleanup TTL.
set -euo pipefail
NS=${NS:-transpara}
DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
FROM=${1:-0.272.0}
TO=${2:-$(kubectl -n $NS get cm tinstaller-state -o jsonpath='{.data.INSTALLER_VERSION}')}
API_IMG=$(kubectl -n $NS get deploy tsystem-api -o jsonpath='{.spec.template.spec.containers[0].image}')
REPO=${API_IMG%%/tsystem-api*}
MIG_IMG="$REPO/tinstaller-migrations:$TO"
JOB=migrations-replay-$(date +%s)
echo "FROM=$FROM TO=$TO DRY_RUN=$DRY"
echo "runner image:     $API_IMG"
echo "migrations image: $MIG_IMG"

PY=$(cat <<EOF
import json, sys, yaml, httpx
from kubernetes import config
config.load_incluster_config()
from app.upgrade.migrations.runner import ClusterMigrationRunner
FROM, TO, NS, DRY = "$FROM", "$TO", "$NS", $DRY
r = ClusterMigrationRunner(); r.load("/shared/migrations")
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

kubectl -n $NS get deploy tsystem-api -o json | jq --arg job "$JOB" --arg mig "$MIG_IMG" --arg py "$PY" '
  .spec.template.spec as $p | ($p.containers[0]) as $c | {
  apiVersion: "batch/v1", kind: "Job",
  metadata: {name: $job, labels: {app: "migrations-replay"}},
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
  }}}}' | kubectl apply -f -

kubectl -n $NS wait --for=condition=complete --timeout=20m job/$JOB &
W1=$!
kubectl -n $NS wait --for=condition=failed --timeout=20m job/$JOB && kill $W1 2>/dev/null || true
wait $W1 2>/dev/null || true
kubectl -n $NS logs job/$JOB -c migrate --tail=-1
kubectl -n $NS get job $JOB -o jsonpath='{"\nJob result: succeeded="}{.status.succeeded}{" failed="}{.status.failed}{"\n"}'
if [ $DRY = 0 ] && [ "$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}')" = 1 ]; then
  kubectl -n $NS patch cm tinstaller-state --type merge -p "{\"data\":{\"MIGRATIONS_APPLIED_THROUGH\":\"$TO\"}}"
  echo "tinstaller-state MIGRATIONS_APPLIED_THROUGH=$TO"
fi
