set shell := ["/bin/fish", "-c"]

#
SYSTEMD_DIR := "~/.config/containers/systemd"

# local directory to backup
backup-dir := "~/podman_volume_backup"
books-dir := "/mnt/nas/media/books"
audiobooks-dir := "/mnt/nas/media/audiobooks/"

# remote backup locations
remote-backup-dir := "/mnt/nas/backup/"
remote-podman-backup-dir := "/mnt/nas/backup/podman-volumes/"
remote-books-backup-dir := "/mnt/nas/backup/books/"
remote-audiobooks-backup-dir := "/mnt/nas/backup/audiobooks/"

# restic retention policy
restic-forget := "forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6"

show-status:
    systemctl --user list-units --quiet --plain --type=service | grep pod | grep -v podman

list-pods:
    #!/usr/bin/env fish
    find quadlets/ -name "*.pod" | while read -l pod_file
        echo (basename $pod_file)
    end

list-pod-services:
    #!/usr/bin/env fish
    just list-pods | while read -l pod_name
        echo $pod_name | sed 's/\.pod/-pod.service/'
    end

list-pod-containers pod:
    podman inspect {{pod}} | jq '.[] | .Containers[].Name'

list-container-volumes container:
    podman inspect {{container}} | jq -r '[.[].Mounts].[].[]|select(.Type == "volume")|.Name'

start-all:
    #!/usr/bin/env fish
    just list-pod-services | while read -l service_name
        # check if service is already running
        if systemctl --user is-active --quiet $service_name
            echo "$service_name is already running. Skipping..."
            continue
        else
            echo "$service_name is not running. Starting..."
            systemctl --user start $service_name
        end
    end

restart-all:
    #!/usr/bin/env fish
    systemctl --user list-units --quiet --plain --type=service | grep pod | grep -v podman | cut -f1 -d" " | while read -r service
        echo "Restarting $service..."
        systemctl --user restart $service
    end

## 

clean-symlinks:
    #!/usr/bin/env fish
    find {{ SYSTEMD_DIR }} -type l | while read -l symlink
        set target (readlink $symlink)
        if not test -e $target
            echo "❗ Removing broken symlink: $symlink"
            rm $symlink
        end
    end
##

get-restic-password:
    sops decrypt .secrets/secrets.yaml | yq '.secrets.restic-password'

backup:
    just backup-volumes
    just backup-with-restic

backup-volumes:
    #!/usr/bin/env fish
    set BACKUP_FOLDER "$HOME/podman_volume_backup"
    # List of pods to skip (add pod names here, e.g., "ollama.pod")
    set SKIP_PODS "ollama.pod" "transmission.pod"
    
    just list-pod-services | while read -l service_name
        set pod_name (echo $service_name | sed 's/-pod.service/\.pod/')
        
        # Check if this pod should be skipped
        if contains $pod_name $SKIP_PODS
            echo "Skipping backup for: $pod_name"
            continue
        end
        
        set volume_list
        just list-pod-containers $pod_name | while read -l container_name
            just list-container-volumes $container_name | while read -l volume_name
                set -a volume_list $volume_name
            end
        end
        systemctl --user stop $service_name
        for volume_name in $volume_list
            echo "Backing up volume: $volume_name"
            if test -n "$volume_name"
                set volume_name_backup (string replace ":" "_" $volume_name)
                # Create a backup using podman
                set backup_file "$BACKUP_FOLDER/$volume_name_backup.tar.gz"
                echo $backup_file
                rm $backup_file
                podman volume export $volume_name | gzip > $backup_file
                echo "Backup created: $backup_file"
            end
        end
        systemctl --user start $service_name
    end

backup-with-restic:
    #!/usr/bin/env fish

    restic --password-command 'just get-restic-password' -r {{ remote-podman-backup-dir }} backup {{ backup-dir }}
    restic --password-command 'just get-restic-password' -r {{ remote-podman-backup-dir }} {{ restic-forget }}

    restic --password-command 'just get-restic-password' -r {{ remote-books-backup-dir }} backup {{ books-dir }}
    restic --password-command 'just get-restic-password' -r {{ remote-books-backup-dir }} {{ restic-forget }}

    restic --password-command 'just get-restic-password' -r {{ remote-audiobooks-backup-dir }} backup {{ audiobooks-dir }}
    restic --password-command 'just get-restic-password' -r {{ remote-audiobooks-backup-dir }} {{ restic-forget }}
