# Justfile for managing Podman pods and services

# create podman secrets from encrypted secrets file
create-secrets:
    #!/usr/bin/env fish

    sops decrypt .secrets/secrets.yaml | yq .secrets | while read -l secret
    set -l parts (string split ": " -- $secret)
    set -l name $parts[1]
    set -l value (string join ": " $parts[2..-1])

    if podman secret exists $name
        echo "Secret $name already exists, skipping..."
        continue
    else
        echo "Creating secret $name..."
    end

    # remove the leading and trailing single quotes if they exist
    set value (string trim -c "'" -- $value)

    echo -n $value | podman secret create $name -
    end

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
    podman inspect {{pod}} | jq '.[] | .Containers[].Name'

# list volumes used by a container
list-container-volumes container:
    podman inspect {{container}} | jq -r '[.[].Mounts].[].[]|select(.Type == "volume")|.Name'

# start all podman pod services
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

# restart all podman pod services
restart-all:
    #!/usr/bin/env fish
    just list-pod-services | while read -l service_name
        echo "Restarting $service_name..."
        systemctl --user restart $service_name
    end

# stop all podman pod services
stop-all:
    #!/usr/bin/env fish
    just list-pod-services | while read -l service_name
        echo "Stopping $service_name..."
        systemctl --user stop $service_name
    end