#!/usr/bin/env bash
# Upgrade a quadlet service's PostgreSQL cluster across a major-version
# boundary using pg_upgrade --link, before the new image is started.
#
# usage: postgres-major-upgrade.sh <quadlet-dir> [--new-image IMAGE] [--dry-run] [--no-start]
#
# Handles official `postgres` images only. Aborts for postgis/pgvector/
# immich-app/postgres variants and for custom PGDATA overrides.
#
# Safe by default: on failure the new cluster is discarded and the installed
# unit is rolled back to the old image so the service keeps running.
set -euo pipefail

die() { echo "❌ $*" >&2; exit 1; }
log() { echo "🔄 $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: postgres-major-upgrade.sh <quadlet-dir> [--new-image IMAGE] [--dry-run] [--no-start]

  --new-image IMAGE  image to upgrade to (default: the installed unit's Image=)
  --dry-run          report what would happen without stopping anything
  --no-start         leave the pod stopped after a successful upgrade
EOF
  exit 2
}

[ $# -ge 1 ] || usage
DIR=$1
shift

NEW_IMAGE=""
DRY_RUN=0
NO_START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --new-image)
      [ $# -ge 2 ] || usage
      NEW_IMAGE=$2
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-start) NO_START=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$DIR" ] || die "no such directory: $DIR"

INSTALLED_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd

major_of() {
  local img=$1 tag major
  case "$img" in
    postgres:*|*[/:]postgres:*) ;;
    *) return 1 ;;
  esac
  tag=${img##*:}
  major=${tag%%.*}
  major=${major%%-*}
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$major"
}

quadlet_volume_name() {
  local ref=$1 vol
  vol=$ref
  if [ -f "$DIR/$ref" ]; then
    vol=$(sed -n 's/^VolumeName=//p' "$DIR/$ref" | head -1)
    [ -n "$vol" ] || vol=${ref%.volume}
  fi
  printf '%s\n' "$vol"
}

is_cluster_superuser() {
  local name=$1 user=$2
  [ "$(podman exec "$name" psql -U "$user" -Atc \
        'select rolsuper from pg_roles where rolname = current_user' 2>/dev/null)" = t ]
}

for cf in "$DIR"/*.container; do
  [ -e "$cf" ] || continue

  NAME=$(sed -n 's/^ContainerName=//p' "$cf" | head -1)
  [ -n "$NAME" ] || die "no ContainerName in $cf"

  installed="$INSTALLED_DIR/$(basename "$cf")"
  src=$cf
  if [ -f "$installed" ]; then
    src=$installed
  fi
  image=${NEW_IMAGE:-$(sed -n 's/^Image=//p' "$src" | head -1)}

  case "$image" in
    postgres:*|*[/:]postgres:*) kind=official ;;
    *postgis*|*pgvector*|*immich-app/postgres*) kind=variant ;;
    *) continue ;;
  esac

  podman container exists "$NAME" 2>/dev/null \
    || { log "skip $NAME: no existing container"; continue; }
  old_image=$(podman inspect -f '{{.ImageName}}' "$NAME")

  if [ "$kind" = variant ]; then
    [ "$image" = "$old_image" ] && continue
    die "$NAME: $image needs a manual migration (unsupported postgres variant)"
  fi

  old_major=$(major_of "$old_image") || die "$NAME: unsupported old image: $old_image"
  new_major=$(major_of "$image") || die "$NAME: unsupported new image: $image"
  if [ "$new_major" -le "$old_major" ]; then
    log "skip $NAME: $old_major -> $new_major"
    continue
  fi
  log "$NAME: PostgreSQL $old_major -> $new_major"

  pod_ref=$(sed -n 's/^Pod=//p' "$cf" | head -1)
  [ -n "$pod_ref" ] || die "$NAME: not part of a pod (Pod= is missing)"
  pod_file="$DIR/$pod_ref"
  [ -f "$pod_file" ] || die "$NAME: pod unit $pod_ref not found in $DIR"
  pod_name=$(sed -n 's/^PodName=//p' "$pod_file" | head -1)
  [ -n "$pod_name" ] || pod_name=${pod_ref%.pod}
  POD_SVC="${pod_name}-pod.service"

  envf="$DIR/$NAME.env"
  if [ -f "$envf" ] && grep -q '^PGDATA=' "$envf"; then
    die "$NAME: custom PGDATA is not supported by this script"
  fi

  vol_line=$(grep -E '^Volume=[^:]+:/var/lib/postgresql(:|$)' "$cf" | head -1 || true)
  [ -n "$vol_line" ] || die "$NAME: no volume mounted at /var/lib/postgresql"
  vol_ref=${vol_line#Volume=}
  vol_ref=${vol_ref%%:*}
  case "$vol_ref" in
    */*|.*) die "$NAME: bind-mounted PGDATA is not supported by this script" ;;
  esac
  vol=$(quadlet_volume_name "$vol_ref")

  superuser=postgres
  initdb_args=""
  if [ -f "$envf" ]; then
    user=$(sed -n 's/^POSTGRES_USER=//p' "$envf" | head -1)
    if [ -n "$user" ]; then
      superuser=$user
    fi
    extra=$(sed -n 's/^POSTGRES_INITDB_ARGS=//p' "$envf" | head -1)
    if [ -n "$extra" ] && [[ ! $extra =~ (^|[[:space:]])(-U|--username)([[:space:]]|=) ]]; then
      initdb_args=$extra
    fi
  fi

  [ "$(podman inspect -f '{{.State.Running}}' "$NAME")" = true ] \
    || die "$NAME is not running; start the service first"
  for _ in $(seq 1 30); do
    podman exec "$NAME" pg_isready -q 2>/dev/null && break
    sleep 1
  done
  if ! is_cluster_superuser "$NAME" "$superuser"; then
    if is_cluster_superuser "$NAME" postgres; then
      superuser=postgres
    else
      die "$NAME: could not find a superuser (tried '$superuser' and 'postgres')"
    fi
  fi
  log "$NAME: cluster superuser is $superuser"

  mountpoint=$(podman volume inspect -f '{{.Mountpoint}}' "$vol")
  pgdata_old="/var/lib/postgresql/$old_major/docker"
  pgdata_new="/var/lib/postgresql/$new_major/docker"

  [ "$(podman unshare cat "$mountpoint/$old_major/docker/PG_VERSION" 2>/dev/null || true)" = "$old_major" ] \
    || die "$NAME: expected $old_major data in $mountpoint/$old_major/docker"
  if podman unshare cat "$mountpoint/$new_major/docker/PG_VERSION" >/dev/null 2>&1; then
    die "$NAME: $mountpoint/$new_major/docker already contains a cluster"
  fi
  if [ -e "$mountpoint/.pre-$new_major" ]; then
    die "$NAME: $mountpoint/.pre-$new_major already exists; remove it first"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would upgrade $NAME from $old_major to $new_major on volume $vol"
    continue
  fi

  if [ -n "$NEW_IMAGE" ] && [ -f "$installed" ]; then
    sed -i "s|^Image=.*|Image=$NEW_IMAGE|" "$installed"
    systemctl --user daemon-reload
  fi

  systemctl --user stop "$POD_SVC"
  podman unshare rm -rf "$mountpoint/$new_major"

  upgrade_image="docker.io/tianon/postgres-upgrade:${old_major}-to-${new_major}"
  log "$NAME: pulling $upgrade_image"
  podman pull -q "$upgrade_image" >/dev/null

  init_args="-U $superuser"
  if [ -n "$initdb_args" ]; then
    init_args="$init_args $initdb_args"
  fi

  if ! podman run --rm \
        -v "$vol:/var/lib/postgresql:Z" \
        -e "PGDATAOLD=$pgdata_old" \
        -e "PGDATANEW=$pgdata_new" \
        -e "POSTGRES_INITDB_ARGS=$init_args" \
        "$upgrade_image" --link --username "$superuser"; then
    podman unshare rm -rf "$mountpoint/$new_major"
    if [ -f "$installed" ]; then
      sed -i "s|^Image=.*|Image=$old_image|" "$installed"
      systemctl --user daemon-reload
    fi
    systemctl --user start "$POD_SVC" || true
    die "$NAME: pg_upgrade failed; rolled back to $old_image"
  fi

  # the tianon image initdbs the new cluster itself and does not add the
  # Docker entrypoint's "host all all all" rule, so carry pg_hba.conf over
  podman unshare cp -a \
    "$mountpoint/$old_major/docker/pg_hba.conf" \
    "$mountpoint/$new_major/docker/pg_hba.conf"
  podman unshare mv "$mountpoint/$old_major" "$mountpoint/.pre-$new_major"
  log "$NAME: upgraded to $new_major (old cluster kept at $mountpoint/.pre-$new_major)"

  if [ "$NO_START" -eq 0 ]; then
    systemctl --user start "$POD_SVC"
    for _ in $(seq 1 30); do
      podman container exists "$NAME" && break
      sleep 1
    done
    podman logs --tail=30 "$NAME" || true
  fi
done

log "postgres major upgrade check complete"
