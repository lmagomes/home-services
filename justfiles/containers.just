# Justfile for building container images for various services.
build-all:
    just build-transmission
    just build-caddy
    just build-lumo-tamer
    just build-service-hub
    just build-jsonlint
    just build-json-path-finder
    just build-forgejo-runner-job

# create a container image for service-hub
build-service-hub:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/service-hub/Containerfile | head -1)
    podman build -t localhost/service-hub:$image_version builds/service-hub/

# create a container image for transmission
build-transmission:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/transmission/Containerfile)
    podman build -t transmission-flood:$image_version builds/transmission/

# create a container image for caddy with cloudflare and l4 plugins
build-caddy:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/caddy/Containerfile | tail -1)
    echo $image_version
    podman build -t caddy-cloudflare-l4:$image_version builds/caddy/

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
    podman build -t localhost/dev:$image_version builds/dev/

# create a container image for jsonlint
build-jsonlint:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/jsonlint/Containerfile | tail -1)
    set base_url (sops decrypt .secrets/secrets.yaml | yq '.secrets.jsonlint-app-url')
    echo "Building jsonlint with NEXT_PUBLIC_BASE_URL=$base_url..."
    podman build --build-arg NEXT_PUBLIC_BASE_URL=$base_url -t localhost/jsonlint:$image_version builds/jsonlint/
    echo "Done! Built localhost/jsonlint:$image_version"

# create a container image for json-path-finder
build-json-path-finder:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/json-path-finder/Containerfile | tail -1)
    echo "Building json-path-finder..."
    podman build -t localhost/json-path-finder:$image_version builds/json-path-finder/
    echo "Done! Built localhost/json-path-finder:$image_version"

# create a container image for the forgejo runner job execution environment
build-forgejo-runner-job:
    echo "Building forgejo-runner-job..."
    podman build -t localhost/forgejo-runner-job:latest builds/forgejo-runner-job/
    echo "Done! Built localhost/forgejo-runner-job:latest"

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

    set registry_path (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-path')
    set remote_image "$registry_path/{{ image }}:$image_version"

    echo "🔄 Building {{ image }}:$image_version..."
    podman build -t localhost/{{ image }}:$image_version {{ dir }}

    echo "🔖 Tagging $remote_image..."
    podman tag localhost/{{ image }}:$image_version $remote_image

    echo "📤 Pushing $remote_image..."
    podman push $remote_image

    echo "✅ Pushed $remote_image"

# build and push all images to the forgejo container registry
build-and-push-all:
    just build-and-push caddy-cloudflare-l4 builds/caddy last
    just build-and-push transmission-flood builds/transmission first
    just build-and-push service-hub builds/service-hub first
    just build-and-push json-path-finder builds/json-path-finder last
    just build-and-push forgejo-runner-job builds/forgejo-runner-job "44"
    just build-and-push dev builds/dev first
    echo "❗ Skipped jsonlint — needs secrets, use build-jsonlint + manual push"

# log in to the forgejo container registry (for CI, uses Actions secrets as env vars)
registry-login-ci:
    #!/usr/bin/env fish
    set registry_domain (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-domain')
    echo "$REGISTRY_TOKEN" | podman login $registry_domain -u "$REGISTRY_USER" --password-stdin
    echo "✅ Logged in to $registry_domain container registry"
