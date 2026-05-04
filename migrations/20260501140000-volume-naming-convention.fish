#!/usr/bin/env fish
# Migrate Podman volumes from systemd-<name> to <service>-<purpose> naming.
# Idempotent — safe to run multiple times. Skips volumes that already exist.

# ─── Volume mappings ───────────────────────────────────────────────────────────

# Volumes that kept their filename (old: systemd-<name>, new: <name>)
set -l std_volumes \
    audiobookshelf-config audiobookshelf-metadata \
    authentik-certs authentik-custom-templates authentik-db-data authentik-media \
    bichon-data-index bichon-data-mail bichon-root-dir \
    caddy-config caddy-data \
    calibre-web-automated-config calibre-web-automated-plugins \
    dawarich-db-data dawarich-public dawarich-shared dawarich-storage dawarich-watched \
    firefly-db-data firefly-upload \
    forgejo-data \
    immich-machine-learning-model-cache immich-ml-model-cache immich-postgres-data \
    jellyfin-cache jellyfin-config \
    karakeep-data karakeep-meilisearch-data \
    mealie-data \
    miniflux-db-data \
    mssql \
    paperless-ai-data paperless-consume paperless-data paperless-export \
    paperless-gpt-prompts paperless-media paperless-postgres-data paperless-redis-data \
    termix-data \
    transmission-data transmission-watch-folder

# All mappings: old → new (pairs: old new old new ...)
set -l volume_map

# Standard volumes: systemd-<name> → <name>
for name in $std_volumes
    set -a volume_map systemd-$name $name
end

# Renamed volumes: systemd-<old-name> → <new-name>
set -a volume_map systemd-proton-drive-sync-config  backup-proton-drive-sync-config
set -a volume_map systemd-proton-drive-sync-state   backup-proton-drive-sync-state
set -a volume_map systemd-llamacpp-models           llm-llamacpp-models
set -a volume_map systemd-localai-backends          llm-localai-backends
set -a volume_map systemd-localai-configuration      llm-localai-configuration
set -a volume_map systemd-lumo-tamer-sessions       llm-lumo-tamer-sessions
set -a volume_map systemd-open-webui-data           llm-open-webui-data
set -a volume_map systemd-argus-data                monitor-argus-data
set -a volume_map systemd-uptime-kuma-data          monitor-uptime-kuma-data
set -a volume_map systemd-jotty-cache               notes-jotty-cache
set -a volume_map systemd-jotty-config              notes-jotty-config
set -a volume_map systemd-jotty-data                notes-jotty-data
set -a volume_map systemd-invidious-companion-cache youtube-invidious-companion-cache
set -a volume_map systemd-invidious-db-data         youtube-invidious-db-data
set -a volume_map systemd-materialious-data         youtube-materialious-data

# ─── Main ──────────────────────────────────────────────────────────────────────

set -l migrated 0
set -l skipped 0
set -l failed 0

echo "🔄 Stopping containers before volume migration..."

set -l pods (systemctl --user list-units --type=service --all --no-legend 2>/dev/null \
    | grep 'pod.*\.service' \
    | awk '{print $1}' \
    | grep -v '^●')

for pod in $pods
    if systemctl --user is-active --quiet $pod 2>/dev/null
        echo "  Stopping $pod"
        systemctl --user stop $pod 2>/dev/null
    end
end

sleep 2
echo ""

set -l i 1
while test $i -le (count $volume_map)
    set old_name $volume_map[$i]
    set new_name $volume_map[(math "$i + 1")]
    set i (math "$i + 2")

    # Old volume doesn't exist — nothing to migrate
    if not podman volume inspect "$old_name" >/dev/null 2>/dev/null
        continue
    end

    # New volume already exists — skip (idempotent)
    if podman volume inspect "$new_name" >/dev/null 2>/dev/null
        echo "⏭️  $new_name already exists — skipping"
        set skipped (math "$skipped + 1")
        continue
    end

    echo "🔄 $old_name → $new_name"

    if not podman volume create "$new_name" >/dev/null 2>/dev/null
        echo "  ❌ Failed to create volume: $new_name"
        set failed (math "$failed + 1")
        continue
    end

    set old_mount (podman volume inspect "$old_name" --format '{{.Mountpoint}}')
    set new_mount (podman volume inspect "$new_name" --format '{{.Mountpoint}}')

    if test -d "$old_mount"; and begin
        set -l files (ls -A "$old_mount" 2>/dev/null)
        test -n "$files"
    end
        if cp -a "$old_mount/." "$new_mount/." 2>/dev/null
            echo "  ✅ Data copied"
            set migrated (math "$migrated + 1")
        else
            echo "  ❌ Failed to copy data"
            podman volume rm "$new_name" >/dev/null 2>/dev/null
            set failed (math "$failed + 1")
            continue
        end
    else
        echo "  ✅ Empty volume created"
        set migrated (math "$migrated + 1")
    end
end

echo ""
echo "──────────────────────────────────────────────────"
echo "Volume migration: $migrated migrated, $skipped skipped, $failed failed"

if test $failed -gt 0
    echo "❗ Some volumes failed. Review errors above."
    exit 1
end
