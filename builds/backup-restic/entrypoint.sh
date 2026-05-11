#!/bin/bash
set -euo pipefail

BACKUP_DIR="/data/podman-volume-backup"

SKIP_PODS=("mssql.pod" "transmission.pod" "tools.pod" "backup.pod")
SKIP_VOLUMES=("systemd-llamacpp-models" "systemd-localai-models")

RESTIC_PODMAN_REPO="/data/restic/podman-volumes"
RESTIC_BOOKS_REPO="/data/restic/books"
RESTIC_AUDIOBOOKS_REPO="/data/restic/audiobooks"

BOOKS_DIR="/data/media/books"
AUDIOBOOKS_DIR="/data/media/audiobooks"

mkdir -p "$BACKUP_DIR"

# Process each pod one at a time: stop, export its volumes, restart
for pod in $(podman pod ls --format "{{.Name}}"); do
    # Check if this pod should be skipped
    skip=0
    for sp in "${SKIP_PODS[@]}"; do
        if [[ "$pod" == "$sp" ]]; then
            skip=1
            break
        fi
    done
    if [[ $skip -ne 0 ]]; then
        echo "Skipping pod: $pod"
        continue
    fi

    # Get volumes for all containers in this pod
    volume_list=()
    for container in $(podman inspect "$pod" --format '{{range .Containers}}{{.Name}} {{end}}'); do
        for vol in $(podman inspect "$container" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}'); do
            volume_list+=("$vol")
        done
    done

    # Skip pods with no volumes to avoid unnecessary downtime
    if [[ ${#volume_list[@]} -eq 0 ]]; then
        echo "Skipping pod: $pod (no volumes)"
        continue
    fi

    # Stop the pod
    echo "Stopping pod: $pod"
    podman pod stop "$pod"

    # Export non-skipped volumes
    for volume in "${volume_list[@]}"; do
        skip=0
        for sv in "${SKIP_VOLUMES[@]}"; do
            if [[ "$volume" == "$sv" ]]; then
                skip=1
                break
            fi
        done
        if [[ $skip -eq 0 ]] && [[ -n "$volume" ]]; then
            backup_file="$BACKUP_DIR/${volume//:/_}.tar"
            rm -f "$backup_file"
            podman volume export "$volume" -o "$backup_file"
            echo "Backup created: $backup_file"
        else
            echo "Skipping volume: $volume"
        fi
    done

    # Restart the pod
    echo "Starting pod: $pod"
    podman pod start "$pod"
done

# Restic backup and retention
restic -r "$RESTIC_PODMAN_REPO" backup "$BACKUP_DIR"
restic -r "$RESTIC_PODMAN_REPO" forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6

restic -r "$RESTIC_BOOKS_REPO" backup "$BOOKS_DIR"
restic -r "$RESTIC_BOOKS_REPO" forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6

restic -r "$RESTIC_AUDIOBOOKS_REPO" backup "$AUDIOBOOKS_DIR"
restic -r "$RESTIC_AUDIOBOOKS_REPO" forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
