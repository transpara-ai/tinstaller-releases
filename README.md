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

The upstream repair helpers replay cluster migrations that a direct upgrade from
before 0.274.0 may skip. Inspect the script and confirm the original and target
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
limits a replay and does not advance `MIGRATIONS_APPLIED_THROUGH`.

`fix-skipped-migrations.sh` remains available for compatibility. Prefer
`migration.sh`, which guards against an active upgrade Job before a full replay
and explicitly sets the replay Job namespace.
