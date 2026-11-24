# PostgreSQL major-version upgrades

Docker PostgreSQL images 18 and newer store data in
`/var/lib/postgresql/<major>/docker`. Bumping the image to a new major (for
example `postgres:18.7` → `postgres:19.0`) without migrating the data makes the
new image **refuse to start**:

```
Error: in 18+, these Docker images are configured to store database data in a
       format which is compatible with "pg_ctlcluster" ...
       Counter to that, there appears to be PostgreSQL data in:
         /var/lib/postgresql/18/docker
```

The data is not lost — the new image exits before touching it. The fix is to
run `pg_upgrade` against the old cluster before the new image starts.

## Automated path

`just update-podman-images` runs the migration before it restarts a pod, but
only for quadlet dirs that declare a Postgres-family image (`postgres`,
`postgis`, `pgvector`, `immich-app/postgres`):

```
if <dir contains a postgres-family image>:
    bash scripts/postgres-major-upgrade.sh <quadlet-dir> --no-start
systemctl --user restart <service>-pod.service
```

Non-Postgres deployments are unaffected and never call the script.

Because `.forgejo/workflows/build-images.yml` runs
`just update-podman-images-since` after `just install-quadlets`, merging a
Renovate major bump migrates the database automatically.

What `scripts/postgres-major-upgrade.sh` does:

1. Compares the running container's image major (`podman inspect`) with the
   installed unit's `Image=` major (`~/.config/containers/systemd/`). If they
   match, it is a no-op.
2. Only handles the official `postgres` image. It aborts with a clear message
   for `postgis`, `pgvector` and `immich-app/postgres` variants, and for a
   custom `PGDATA` override.
3. Discovers the cluster superuser from `<container-name>.env`
   (`POSTGRES_USER`), verifies it with `psql`, and falls back to `postgres`.
4. Stops the pod, removes any stale `<new-major>/` directory, and runs
   `docker.io/tianon/postgres-upgrade:<old>-to-<new> --link --username <user>`.
5. Copies the old `pg_hba.conf` into the new cluster (the tianon image's
   `initdb` does not add Docker's `host all all all` rule).
6. Renames the old cluster directory to `.pre-<new>` so the new image's
   `*/docker` scan ignores it.
7. Leaves the pod stopped; the caller restarts it. With `--no-start` omitted,
   the script restarts the pod itself.

Useful flags:

```
bash scripts/postgres-major-upgrade.sh quadlets/portabase --dry-run
bash scripts/postgres-major-upgrade.sh quadlets/portabase
bash scripts/postgres-major-upgrade.sh quadlets/portabase --new-image docker.io/postgres:19.0
```

On failure the new cluster is discarded, the installed unit is rolled back to
the old image, and the pod is restarted on the old version. The deploy exits
non-zero, so the service stays up and the failure is visible.

## Testing on portabase

Portabase is the first service to use the automated path.

1. Merge the automation change first; with no image bump it is a no-op.
2. Merge the portabase `postgres:18.7` → `19.0` PR.
3. The deploy stops `portabase-pod.service`, runs the upgrade, and restarts the
   pod on 19. Check:

   ```
   podman logs --tail=50 portabase-db
   podman logs --tail=50 portabase
   ```

To rehearse by hand before merging the bump:

```
# simulate what install-quadlets will install after the bump
sed -i 's|postgres:18.7|postgres:19.0|' ~/.config/containers/systemd/portabase-db.container
systemctl --user daemon-reload

bash scripts/postgres-major-upgrade.sh quadlets/portabase --dry-run
bash scripts/postgres-major-upgrade.sh quadlets/portabase
```

## Manual fallback

Use this when the automation aborts (variant image, custom `PGDATA`, or a
service that is already crash-looping on the new image).

```bash
set -euo pipefail

VOL=authentik-db-data
APP=authentik-pod.service
DB=authentik-db
SUPERUSER=authentik

systemctl --user stop "$APP"
M=$(podman volume inspect -f '{{.Mountpoint}}' "$VOL")

# sanity: old cluster present, no new-major cluster yet
podman unshare cat "$M/18/docker/PG_VERSION"
podman unshare rm -rf "$M/19"

# upgrade (hardlinks, no dump)
podman run --rm \
  -v "$VOL:/var/lib/postgresql:Z" \
  -e "POSTGRES_INITDB_ARGS=-U $SUPERUSER" \
  docker.io/tianon/postgres-upgrade:18-to-19 \
  --link --username "$SUPERUSER"

# tianon's initdb does not add Docker's host-auth rule
podman unshare cp -a "$M/18/docker/pg_hba.conf" "$M/19/docker/pg_hba.conf"

# hide the old cluster; the 19+ entrypoint scans */docker and ignores dot dirs
podman unshare mv "$M/18" "$M/.pre-19"

systemctl --user start "$APP"
```

If the app logs `no pg_hba.conf entry for host ...`, add the rule live:

```bash
podman exec -u postgres "$DB" sh -c \
  'echo "host all all all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
podman exec -u postgres "$DB" pg_ctl reload -D "$PGDATA"
```

Recommended by `pg_upgrade` after the new server is up:

```bash
podman exec "$DB" vacuumdb -U "$SUPERUSER" --all --analyze-in-stages --missing-stats-only
```

## Rollback and cleanup

The old cluster is kept at `<volume>/.pre-<new>` after a successful upgrade.
After verifying the service, remove it and the upgrade leftovers:

```bash
M=$(podman volume inspect -f '{{.Mountpoint}}' authentik-db-data)
podman unshare rm -rf \
  "$M/.pre-19" \
  "$M/delete_old_cluster.sh" \
  "$M/19/docker/pg_upgrade_output.d"
```

To roll back before deleting `.pre-<new>`:

```bash
systemctl --user stop authentik-pod.service
podman unshare rm -rf "$M/19"
podman unshare mv "$M/.pre-19" "$M/18"
sed -i 's|postgres:19.0|postgres:18.7|' ~/.config/containers/systemd/authentik-db.container
systemctl --user daemon-reload
systemctl --user start authentik-pod.service
```

`--link` is one-way: once the new cluster has been started, the old directory
cannot be used as a backup, and a late failure may leave it unusable. Keep
restic backups for those cases.

## Limitations

- Official `postgres` images only. `postgis`, `pgvector` and
  `immich-app/postgres` majors must be migrated by hand (the script aborts
  before restarting the pod). Bookorbit's custom `PGDATA` is also manual.
- One database container per pod is assumed.
- Renovate holds `postgres`, `postgis` and `pgvector` majors for Dependency
  Dashboard approval, so a major never lands unattended.
