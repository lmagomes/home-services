build-all:
    just build-transmission
    just build-caddy

build-transmission:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/transmission/Containerfile)
    podman build -t transmission-flood:$image_version builds/transmission/

build-caddy:
    #!/usr/bin/env fish
    set image_version (sed -n 's/^FROM .*:\(.*\)$/\1/p' builds/caddy/Containerfile | tail -1)
    echo $image_version
    podman build -t caddy-cloudflare-l4:$image_version builds/caddy/
