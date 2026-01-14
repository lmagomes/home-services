set shell := ["/bin/fish", "-c"]

# List all pod-based services from quadlets
list-pod-services:
    #!/usr/bin/env fish
    find quadlets/ -name "*.pod" | while read -l pod_file
        set pod_name (basename $pod_file)
        echo $pod_name | sed 's/\.pod/-pod.service/'
    end

show-status:
    systemctl --user list-units --quiet --plain --type=service | grep pod | grep -v podman

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
    end 7