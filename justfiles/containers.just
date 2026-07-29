# Justfile for building container images for various services.
build-all:
    just build-transmission
    just build-caddy
    just build-lumo-tamer
    just build-json-path-finder
    just build-forgejo-runner-job
    just build-backup-restic
    just build-dev

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
    set latest_version (cat builds/lumo-tamer/.upstream-version | string trim)
    echo "Building lumo-tamer:$latest_version..."
    podman build -t localhost/lumo-tamer:$latest_version builds/lumo-tamer/
    podman tag localhost/lumo-tamer:$latest_version localhost/lumo-tamer:latest
    echo "Done! Built localhost/lumo-tamer:$latest_version"

# create a container image for backup-restic
build-backup-restic:
    #!/usr/bin/env fish
    set image_version "44"
    set build_version (cat builds/backup-restic/build-version | string trim)
    set image_version "$image_version-r$build_version"
    podman build -t localhost/backup-restic:$image_version builds/backup-restic/
    podman tag localhost/backup-restic:$image_version localhost/backup-restic:latest

# create a container image for the dev environment
build-dev:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/dev/Containerfile)
    set build_version (cat builds/dev/build-version | string trim)
    set image_version "$image_version-r$build_version"
    podman build --build-arg CACHEBUST=(date +%s) -t localhost/dev:$image_version builds/dev/
    podman tag localhost/dev:$image_version localhost/dev:latest

# create a container image for json-path-finder
build-json-path-finder:
    #!/usr/bin/env fish
    set latest_version (cat builds/json-path-finder/.upstream-version | string trim)
    echo "Building json-path-finder..."
    podman build -t localhost/json-path-finder:$latest_version builds/json-path-finder/
    podman tag localhost/json-path-finder:$latest_version localhost/json-path-finder:latest
    echo "Done! Built localhost/json-path-finder:$latest_version"

# create a container image for the forgejo runner job execution environment
build-forgejo-runner-job:
    #!/usr/bin/env fish
    set image_version "44"
    set build_version (cat builds/forgejo-runner-job/build-version | string trim)
    set image_version "$image_version-r$build_version"
    podman build -t localhost/forgejo-runner-job:$image_version builds/forgejo-runner-job/
    podman tag localhost/forgejo-runner-job:$image_version localhost/forgejo-runner-job:latest
    echo "Done! Built localhost/forgejo-runner-job:$image_version"

# fetch the latest release version from a GitHub repository
github-latest-version repo:
    curl -s https://api.github.com/repos/{{ repo }}/releases/latest | jq -r '.tag_name'

# build and push a container image to the forgejo container registry.
# version-strategy: "first" (first FROM line), "last" (last FROM line), "github:owner/repo", "rpm:package-name", "upstream-file:<path>", or literal version string.
build-and-push image dir version-strategy:
    #!/usr/bin/env fish
    set -l image_version
    set -l skip_build false
    if test "{{ version-strategy }}" = "first"
        set image_version (sed -n 's/^FROM .*:\([^ ]*\).*/\1/p' {{ dir }}/Containerfile | head -1)
    else if test "{{ version-strategy }}" = "last"
        set image_version (sed -n 's/^FROM .*:\([^ ]*\).*/\1/p' {{ dir }}/Containerfile | tail -1)
    else if string match -q 'github:*' "{{ version-strategy }}"
        set repo (string replace 'github:' '' "{{ version-strategy }}")
        set image_version (just github-latest-version $repo)
    else if string match -q 'rpm:*' "{{ version-strategy }}"
        set package (string replace 'rpm:' '' "{{ version-strategy }}")
        echo "🔄 Building {{ image }} with temp tag for RPM version extraction..."
        podman build -t localhost/{{ image }}:temp {{ dir }}
        set image_version (podman run --rm localhost/{{ image }}:temp rpm -q --qf '%{VERSION}-%{RELEASE}' $package)
        podman tag localhost/{{ image }}:temp localhost/{{ image }}:$image_version
        podman tag localhost/{{ image }}:temp localhost/{{ image }}:latest
        podman rmi localhost/{{ image }}:temp 2>/dev/null
        set skip_build true
    else if string match -q 'upstream-file:*' "{{ version-strategy }}"
        set file (string replace 'upstream-file:' '' "{{ version-strategy }}")
        set image_version (cat "{{ dir }}/$file" | string trim)
    else
        set image_version "{{ version-strategy }}"
    end

    if test -f {{ dir }}/build-version
        set build_version (cat {{ dir }}/build-version | string trim)
        set image_version "$image_version-r$build_version"
    end

    set registry_path (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-path')
    set remote_image "$registry_path/{{ image }}:$image_version"

    if not $skip_build
        echo "🔄 Building {{ image }}:$image_version..."
        podman build -t localhost/{{ image }}:$image_version {{ dir }}
        podman tag localhost/{{ image }}:$image_version localhost/{{ image }}:latest
    end

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
            case json-path-finder
                just build-and-push json-path-finder builds/json-path-finder "upstream-file:.upstream-version"
            case lumo-tamer
                just build-and-push lumo-tamer builds/lumo-tamer "upstream-file:.upstream-version"
            case backup-restic
                just build-and-push backup-restic builds/backup-restic "44"
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
    #!/usr/bin/env fish
    just build-and-push caddy-cloudflare-l4 builds/caddy last
    just build-and-push transmission-flood builds/transmission first
    just build-and-push json-path-finder builds/json-path-finder "upstream-file:.upstream-version"
    just build-and-push forgejo-runner-job builds/forgejo-runner-job "44"
    just build-and-push dev builds/dev first
    just build-and-push lumo-tamer builds/lumo-tamer "upstream-file:.upstream-version"
    just build-and-push backup-restic builds/backup-restic "44"


# log in to the forgejo container registry (for CI, uses Actions secrets as env vars)
registry-login-ci:
    #!/usr/bin/env fish
    set registry_domain (sops decrypt .secrets/secrets.yaml | yq '.secrets.registry-domain')
    echo "$REGISTRY_TOKEN" | podman login $registry_domain -u "$REGISTRY_USER" --password-stdin
    echo "✅ Logged in to $registry_domain container registry"
