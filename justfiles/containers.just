build-all:
    just build-transmission
    just build-caddy

build-transmission:
    podman build -t transmission-flood:4.0.6 builds/transmission/

build-caddy:
    podman build -t caddy-cloudflare:2.10.2 builds/caddy/