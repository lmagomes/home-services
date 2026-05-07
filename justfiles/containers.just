# Justfile for building container images for various services.
build-all:
    just build-transmission
    just build-caddy
    just build-lumo-tamer
    just build-service-hub
    just build-json-path-finder
    just build-forgejo-runner-job

# create a container image for service-hub
build-service-hub:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/service-hub/Containerfile | head -1)
    set build_version (cat builds/service-hub/build-version | string trim)
    set image_version "$image_version-r$build_version"
    podman build -t localhost/service-hub:$image_version builds/service-hub/
    podman tag localhost/service-hub:$image_version localhost/service-hub:latest

# create a container image for transmission
build-transmission:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/transmission/Containerfile)
    podman build -t transmission-flood:$image_version builds/transmission/
    podman tag transmission-flood:$image_version transmission-flood:latest

# create a container image for caddy with cloudflare and l4 plugins
build-caddy:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/caddy/Containerfile | tail -1)
    echo $image_version
    podman build -t caddy-cloudflare-l4:$image_version builds/caddy/
    podman tag caddy-cloudflare-l4:$image_version caddy-cloudflare-l4:latest

# create a container image for lumo-tamer and the companion browser image
build-lumo-tamer:
    #!/usr/bin/env fish
    # Create temporary directory
    set temp_dir (mktemp -d)
    echo "Cloning repository into $temp_dir..."

    # Clone the repository
    git clone https://github.com/ZeroTricks/lumo-tamer $temp_dir/lumo-tamer

    # Get the latest release version
    echo "Fetching latest release version..."
    set latest_version (curl -s https://api.github.com/repos/ZeroTricks/lumo-tamer/releases/latest | jq -r '.tag_name')
    echo "Latest version: $latest_version"

    # Change to the cloned repository
    cd $temp_dir/lumo-tamer

    # Build the main container with version tag
    echo "Building lumo-tamer:$latest_version..."
    podman build -f Dockerfile -t localhost/lumo-tamer:$latest_version .

    # Build the browser container with latest tag
    echo "Building lumo-tamer-chromium:latest..."
    podman build -f Dockerfile.browser -t localhost/lumo-tamer-chromium:latest .

    # Clean up
    echo "Cleaning up temporary directory..."
    rm -rf $temp_dir

    echo "Done! Built localhost/lumo-tamer:$latest_version and localhost/lumo-tamer-chromium:latest"

build-proton-drive-sync:
    #!/usr/bin/env fish
    # Create temporary directory
    set temp_dir (mktemp -d)
    echo "Cloning repository into $temp_dir..."

    # Clone the repository
    git clone https://github.com/DamianB-BitFlipper/proton-drive-sync.git $temp_dir/proton-drive-sync

    # Get the latest release version
    echo "Fetching latest release version..."
    set latest_version (curl -s https://api.github.com/repos/DamianB-BitFlipper/proton-drive-sync/releases/latest | jq -r '.tag_name')
    echo "Latest version: $latest_version"

    # Change to the cloned repository
    cd $temp_dir/proton-drive-sync

    # Build the main container with version tag
    echo "Building proton-drive-sync:$latest_version..."
    podman build -f docker/Dockerfile -t localhost/proton-drive-sync:$latest_version .

    # Clean up
    echo "Cleaning up temporary directory..."
    rm -rf $temp_dir

    echo "Done! Built localhost/proton-drive-sync:$latest_version"

# create a container image for the dev environment
build-dev:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/dev/Containerfile)
    set build_version (cat builds/dev/build-version | string trim)
    set image_version "$image_version-r$build_version"
    podman build -t localhost/dev:$image_version builds/dev/
    podman tag localhost/dev:$image_version localhost/dev:latest

# create a container image for json-path-finder
build-json-path-finder:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/json-path-finder/Containerfile | tail -1)
    echo "Building json-path-finder..."
    podman build -t localhost/json-path-finder:$image_version builds/json-path-finder/
    podman tag localhost/json-path-finder:$image_version localhost/json-path-finder:latest
    echo "Done! Built localhost/json-path-finder:$image_version"

# create a container image for the forgejo runner job execution environment
build-forgejo-runner-job:
    #!/usr/bin/env fish
    set image_version "44"
    set build_version (cat builds/forgejo-runner-job/build-version | string trim)
    set image_version "$image_version-r$build_version"
    podman build -t localhost/forgejo-runner-job:$image_version builds/forgejo-runner-job/
    podman tag localhost/forgejo-runner-job:$image_version localhost/forgejo-runner-job:latest
    echo "Done! Built localhost/forgejo-runner-job:$image_version"

# build and push a container image to the forgejo container registry.
# version-strategy: "first" (first FROM line), "last" (last FROM line), or literal version string.
build-and-push image dir version-strategy:
    #!/usr/bin/env fish
    set -l image_version
    if test "{{ version-strategy }}" = "first"
        set image_version (sed -n 's/^FROM .*:\([^ ]*\).*/\1/p' {{ dir }}/Containerfile | head -1)
    else if test "{{ version-strategy }}" = "last"
        set image_version (sed -n 's/^FROM .*:\([^ ]*\).*/\1/p' {{ dir }}/Containerfile | tail -1)
    else
        set image_version "{{ version-strategy }}"
    end

    if test -f {{ dir }}/build-version
        set build_version (cat {{ dir }}/build-version | string trim)
        set image_version "$image_version-r$build_version"
    end

    set registry_path (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-path')
    set remote_image "$registry_path/{{ image }}:$image_version"

    echo "🔄 Building {{ image }}:$image_version..."
    podman build -t localhost/{{ image }}:$image_version {{ dir }}
    podman tag localhost/{{ image }}:$image_version localhost/{{ image }}:latest

    echo "🔖 Tagging $remote_image..."
    podman tag localhost/{{ image }}:$image_version $remote_image
    podman tag localhost/{{ image }}:$image_version "$registry_path/{{ image }}:latest"

    echo "📤 Pushing $remote_image..."
    podman push $remote_image
    podman push "$registry_path/{{ image }}:latest"

    echo "✅ Pushed $remote_image"

# detect changed build directories since previous commit and build+push them (for CI)
build-and-push-changed:
    #!/usr/bin/env fish
    set changed_dirs (git diff --name-only HEAD~1 HEAD -- builds/ | cut -d'/' -f2 | sort -u)

    if test (count $changed_dirs) -eq 0
        echo "No build directories changed."
        exit 0
    end

    echo "Changed build directories: $changed_dirs"

    for dir in $changed_dirs
        switch $dir
            case caddy
                just build-and-push caddy-cloudflare-l4 builds/caddy last
            case transmission
                just build-and-push transmission-flood builds/transmission first
            case service-hub
                just build-and-push service-hub builds/service-hub first
            case json-path-finder
                just build-and-push json-path-finder builds/json-path-finder last
            case forgejo-runner-job
                just build-and-push forgejo-runner-job builds/forgejo-runner-job "44"
            case dev
                just build-and-push dev builds/dev first
            case '*'
                echo "⏭️  No build-and-push configured for builds/$dir"
        end
    end

# build and push all images to the forgejo container registry
build-and-push-all:
    just build-and-push caddy-cloudflare-l4 builds/caddy last
    just build-and-push transmission-flood builds/transmission first
    just build-and-push service-hub builds/service-hub first
    just build-and-push json-path-finder builds/json-path-finder last
    just build-and-push forgejo-runner-job builds/forgejo-runner-job "44"
    just build-and-push dev builds/dev first


# log in to the forgejo container registry (for CI, uses Actions secrets as env vars)
registry-login-ci:
    #!/usr/bin/env fish
    set registry_domain (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-domain')
    echo "$REGISTRY_TOKEN" | podman login $registry_domain -u "$REGISTRY_USER" --password-stdin
    echo "✅ Logged in to $registry_domain container registry"
