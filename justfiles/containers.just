# Justfile for building container images for various services.
build-all:
    just build-transmission
    just build-caddy
    just build-lumo-tamer
    just build-service-hub

# create a container image for service-hub
build-service-hub:
    podman build -t service-hub:latest builds/service-hub/

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
    set latest_version (curl -s https://api.github.com/repos/ZeroTricks/lumo-tamer/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
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
