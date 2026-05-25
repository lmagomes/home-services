# Justfile for managing Podman pods and services

# sync podman secrets with encrypted secrets file
sync-secrets:
    #!/usr/bin/env fish

    # Decrypt to temp file to preserve multi-line YAML
    set -l tmp (mktemp)
    sops decrypt .secrets/secrets.yaml > $tmp

    # Get all secret names
    set -l desired_names (yq '.secrets | keys | .[]' $tmp)

    # Get existing podman secrets
    set -l existing (podman secret ls --noheading | awk '{print $2}')

    # Delete secrets not present in the file
    for name in $existing
        if not contains -- $name $desired_names
            echo "🗑️  Removing orphan secret $name..."
            podman secret rm $name
        end
    end

    # Create or recreate secrets from the file
    for name in $desired_names
        set -l raw_value (yq -r ".secrets.\"$name\"" $tmp)

        # Strip surrounding double-quotes that SOPS may add
        set raw_value (string trim -c '"' -- $raw_value)
        # Convert literal \n to actual newlines (e.g. for PEM keys)
        set -l value (printf '%b' $raw_value)

        if podman secret exists $name
            set -l current (podman secret inspect --showsecret $name | jq -r '.[0].SecretData')
            if test "$current" = "$value"
                echo "🔒 Secret $name is up to date, skipping..."
                continue
            end
            podman secret rm $name >/dev/null 2>&1
            echo "🔄 Recreating secret $name..."
        else
            echo "✅ Creating secret $name..."
        end

        printf '%s' $value | podman secret create $name -
    end

    rm $tmp

# show status of podman pod services
show-status:
    systemctl --user list-units --quiet --plain --type=service | grep pod | grep -v podman

# list all podman pods defined in quadlets
list-pods:
    #!/usr/bin/env fish
    find quadlets/ -name "*.pod" | while read -l pod_file
        echo (basename $pod_file)
    end

# list podman pod services
list-pod-services:
    #!/usr/bin/env fish
    just list-pods | while read -l pod_name
        echo $pod_name | sed 's/\.pod/-pod.service/'
    end

# list containers in a pod
list-pod-containers pod:
    podman inspect {{ pod }} | jq '.[] | .Containers[].Name'

# list volumes used by a container
list-container-volumes container:
    podman inspect {{ container }} | jq -r '[.[].Mounts].[].[]|select(.Type == "volume")|.Name'

# start all podman pod services
start-all:
    #!/usr/bin/env fish
    just list-pod-services | while read -l service_name
        # check if service is already running
        if systemctl --user is-active --quiet $service_name
            echo "✅ $service_name is already running. Skipping..."
            continue
        else
            echo "🔄 $service_name is not running. Starting..."
            systemctl --user start $service_name
        end
    end

# restart all podman pod services
restart-all:
    #!/usr/bin/env fish
    just list-pod-services | while read -l service_name
        echo "🔄 Restarting $service_name..."
        systemctl --user restart $service_name
    end

# stop all podman pod services
stop-all:
    #!/usr/bin/env fish
    just list-pod-services | while read -l service_name
        echo "🔄 Stopping $service_name..."
        systemctl --user stop $service_name
    end

# decrypt quadlet config files stored encrypted (e.g., forgejo-runner-config.yml)
decrypt-quadlet-configs:
    #!/usr/bin/env fish
    for encrypted in (find quadlets/ -name "*.encrypted.*")
        set decrypted (string replace ".encrypted." "." -- $encrypted)
        set ext (string replace -r ".*\\.encrypted\\." "" -- $encrypted)
        if test "$ext" = "yml" -o "$ext" = "yaml"
            set type yaml
        else if test "$ext" = "json"
            set type json
        else
            echo "⚠️ Unknown file type .$ext, skipping $encrypted"
            continue
        end
        echo "🔓 Decrypting $encrypted → $decrypted"
        sops decrypt --input-type $type --output-type $type $encrypted > $decrypted
    end
    echo "✅ Quadlet configs decrypted"

# log in to the forgejo container registry
registry-login:
    #!/usr/bin/env fish
    set user (sops decrypt .secrets/secrets.yaml | yq '.secrets.forgejo-registry-user')
    set token (sops decrypt .secrets/secrets.yaml | yq '.secrets.forgejo-registry-token')
    if test -z "$user" -o -z "$token" -o "$user" = "null" -o "$token" = "null"
        echo "❌ forgejo-registry-user and forgejo-registry-token must be set in .secrets/secrets.yaml"
        exit 1
    end
    set registry_domain (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-domain')
    echo "$token" | podman login $registry_domain -u "$user" --password-stdin
    echo "✅ Logged in to $registry_domain container registry"
