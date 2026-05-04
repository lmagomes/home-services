---
name: quadlet-reference
description: Complete reference for writing Podman Quadlet files — templates, directive ordering, and detailed guidance for pods, containers, volumes, and networks
---

## Overview

All quadlet files use INI-style systemd unit syntax. This skill contains the full templates and detailed directive reference for writing correct quadlet files.

## Pod files (`.pod`)

```ini
[Unit]
Description=<Service> pod managed by Podman
After=network-online.target

[Pod]
PodName=<service>.pod
Network=services.network
# PublishPort=<host>:<container>[/protocol]
# UserNS=keep-id:uid=1000,gid=1000   (only for services needing host UID mapping, see below)

[Install]
WantedBy=default.target
```

- `PodName` must end with `.pod`.
- Always include `[Install]` with `WantedBy=default.target` — this ensures the service can be enabled at boot via `systemctl --user enable`. Omitting it means the service won't auto-start after a reboot.
- Always include `Network=services.network` unless the pod needs an isolated network (e.g., `mssql` uses its own `mssql.network`).
- Only add `PublishPort` for services that need host-level port exposure (e.g., Caddy on 443, Forgejo on 22/3000).
- Rootless containers cannot bind ports < 1024 unless `net.ipv4.ip_unprivileged_port_start=0` is set in `/etc/sysctl.d/`.
- Include protocol suffix for UDP ports: `PublishPort=51413:51413/udp`.

### When to use `UserNS=keep-id`

Only use `UserNS=keep-id:uid=1000,gid=1000` on **pod files** for non-LSIO images that need the container process to run as the host's UID 1000 and access host filesystem resources (e.g., hardware devices via `AddDevice`, or bind mounts that need specific ownership).

Do **NOT** use `UserNS=keep-id` for LSIO / s6-overlay images — it breaks `s6-applyuidgid`. Use `PUID=0` / `PGID=0` for those instead (see PUID/PGID section below).

Valid use: `jellyfin.pod` (needs `/dev/dri` GPU access), `notes.pod` (needs host user ownership).
Invalid use: Any LSIO-based image.

## Container files (`.container`)

Section order: `[Unit]` → `[Container]` → `[Service]` → `[Install]`.

Within `[Container]`, follow this directive ordering: `Pod=` → `ContainerName=` → `Image=` → `EnvironmentFile=` → `Environment=` → `Secrets` → `PodmanArgs` → `Volumes` (including `Mount=`) → `AddDevice=` → `ShmSize=` → `User=` → `SecurityLabelDisable=` → `Exec=` / `Entrypoint=` → `AutoUpdate=` → `Health*`.

```ini
[Unit]
Description=<Component> container managed by Podman
After=network.target
# Requires=<dependency>.service    (if this container depends on another container)
# After=<dependency>.service       (always pair with Requires)

[Container]
Pod=<service>.pod
ContainerName=<container-name>
Image=<registry>/<image>:<version>
EnvironmentFile=./%n.d/env
# Environment=KEY=value            (inline env; prefer .env file)
# Secret=<secret-name>,type=env,target=<ENV_VAR>
# Volume=<volume-name>.volume:<mount-path>:Z
# Volume=<volume-name>.volume:<mount-path>:ro,Z           (read-only named volume)
# Volume=./%n.d/<config-file>:<container-path>:ro,Z      (read-only config bind mount)
# Mount=type=bind,source=<host-path>,destination=<container-path>,relabel=private
# Mount=type=bind,source=<host-path>,destination=<container-path>,ro=true,relabel=private
# User=0                                                   (run as container root; needed for podman socket access)
# SecurityLabelDisable=true                                (disable SELinux; required when mounting the podman socket)
# Exec=<command>                                           (override image CMD)
# Entrypoint=<command>                                     (override image ENTRYPOINT)
# TimeoutStopSec=<seconds>                                 (graceful shutdown timeout, default: 10)
# AutoUpdate=registry                                      (auto-pull new image on restart; use sparingly)

[Service]
Restart=always                     # or on-failure
# TimeoutStopSec=<seconds>         (also valid here)

[Install]
WantedBy=multi-user.target         # or default.target
```

## Detailed directive reference

**Image version pinning**: Pin image versions explicitly (e.g., `v2.6.2`, `18.1`). Avoid `:latest` and similar floating tags (e.g., `:lts`, `:2022-latest`). Verify the exact tag exists on the upstream registry.

**For locally-built images**: Tag as `localhost/<image-name>:<version>` (e.g., `localhost/caddy-cloudflare-l4:2.11.2-alpine`). Build recipes should extract the version from the base image's `FROM` line — do not leave locally-built images tagged as `:latest` in container files (use that only during development).

**`%n` (systemd specifier)**: Expands to the unit name (the `.container` filename without `.container`). Always use `./%n.d/env` for the `EnvironmentFile=` directive so the path references the correct `.service.d/` directory. This avoids copy-paste bugs when cloning containers.

**EnvironmentFile sharing**: In most cases, each container should reference its own env file via `EnvironmentFile=./%n.d/env`. However, when two containers run the same application image but with different entrypoints (e.g., `dawarich-app` + `dawarich-sidekiq`), both should reference their own env files with their specific config. For helper containers that genuinely share all configuration with the main container (e.g., `firefly-cron` sharing `firefly`'s env vars), reference the main container's env file explicitly — this is the exception, not the rule.

**`Environment=`**: Only use inline environment variables when the value is trivial (no secrets, no long strings) and there are ≤ 2 variables. Prefer `.service.d/env` files for all other cases. Example: `Environment=MEILI_NO_ANALYTICS="true"`.

**Secrets**: Group together. Use native `Secret=<name>,type=env,target=<ENV_VAR>` syntax. When referencing secrets, always comment them out in the `.service.d/env` file with:
```
#DATABASE_PASSWORD is set via Secret in the .container file
```

**Legacy secret syntax (`PodmanArgs`)**: Older Podman versions (pre-4.6) used `PodmanArgs=--secret <name>,type=env,target=<ENV_VAR>`. Existing containers using this syntax are kept for compatibility (e.g., `caddy.container`). New containers must use the native `Secret=` syntax.

**`PodmanArgs=`**: Use only for Podman CLI options that have no Quadlet equivalent. Currently only used for legacy secrets. Do not use for volume mounts, environment variables, or networking — those have dedicated Quadlet directives.

**Volumes**: Group together. Named volumes use the `.volume` suffix with `:Z` for SELinux relabeling (`:Z` = private/single-container label; `:z` = shared/multi-container label — this project always uses `:Z`). Bind mounts use the `Mount=` directive (not `Volume=`), always with `relabel=private` for host paths outside the container's SELinux context. For read-only bind mounts, add `ro=true`:
```
Mount=type=bind,source=/mnt/nas/media/photos,destination=/data,relabel=private
Mount=type=bind,source=/mnt/nas/media,destination=/media,ro=true,relabel=private
```
Do **not** use `idmap` on bind mounts in rootless Podman — `mount_setattr` requires `CAP_SYS_ADMIN` and will fail with `OCI permission denied`.

**Config file mounts**: Attach extra config files as read-only bind mounts using the `Volume=` directive:
```
Volume=./%n.d/config.yml:/app/config.yml:ro,Z
```

**`AddDevice=`**: Use to pass host devices into the container (e.g., `/dev/dri` for GPU access). Usually paired with `UserNS=keep-id` on the pod.

**`ShmSize=`**: Increase shared memory for database containers that need it (e.g., `ShmSize=1G` for PostGIS). Default is 64MB.

**`User=`**: Set `User=0` (container root) only when the container needs to access the Podman socket (`/run/user/%U/podman/podman.sock`). Always pair with `SecurityLabelDisable=true` in these cases. Rootless Podman already maps container root (UID 0) to the host user (UID 1000), so files written by `User=0` processes have correct host ownership.

**`SecurityLabelDisable=true`**: Disables SELinux labeling for the container. Required when mounting the Podman socket (`/run/user/.../podman/podman.sock`). Do not use otherwise — prefer `:Z` on volume mounts for proper SELinux relabeling.

**`Exec=` / `Entrypoint=`**: Override the container's CMD (`Exec`) or ENTRYPOINT (`Entrypoint`). Use `Entrypoint` + `Exec` together when you need to change both the startup script and its arguments (e.g., `dawarich` containers use `Entrypoint=web-entrypoint.sh` + `Exec=bin/rails server ...`).

**PUID/PGID**: For **s6-overlay / LSIO images** (linuxserver.io or other images using `PUID`/`PGID`): set `PUID=0` and `PGID=0` in the env file. Do **not** use `UserNS=keep-id` — it breaks `s6-applyuidgid`. Rootless Podman already maps container root (UID 0) to the host user (UID 1000), so files are written with correct host ownership.

For **non-LSIO images** that happen to accept `PUID`/`PGID` env vars (e.g., `notes-jotty`, `transmission`), use the actual host UID/GID (`PUID=1000`, `PGID=1000`) in the env file — these are handled at the application level, not via s6, and don't need `UserNS=keep-id`.

**`AutoUpdate=registry`**: Auto-pulls the latest image from the registry on each container restart. Use only for containers tracking floating tags where you accept automatic updates (e.g., helper cron containers based on `alpine:latest`). Do not use for pinned-version containers managed by `update-quadlet-pr`.

**Health checks**: Place `HealthCmd`, `HealthInterval`, `HealthRetries`, `HealthTimeout`, and `HealthStartPeriod` at the end of the `[Container]` section (after volumes and before `[Service]`):
```ini
HealthCmd=pg_isready -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-dawarich}
HealthInterval=30s
HealthTimeout=5s
HealthRetries=2
HealthStartPeriod=10s
```

**Service dependencies**: Use `Requires=` + `After=` together in `[Unit]` to express that a container depends on another container being healthy before it starts. For example:
```ini
Requires=authentik-db.service
After=network.target authentik-db.service
```

**Restart policy**:
- `always` — for long-running services that should always be up
- `on-failure` — for one-off tasks or services where a clean exit is normal

## Volume files (`.volume`)

Each volume file should include a `[Unit]` Description and an explicit `VolumeName` (without the `systemd-` prefix):

```ini
[Unit]
Description=<Name> volume

[Volume]
VolumeName=<service>-<purpose>
```

- `VolumeName` must match the filename (without `.volume`).
- Explicit `VolumeName` prevents the auto-generated `systemd-` prefix, keeping podman volume names clean.
- Add `Device=` or `Options=` only when needed for external storage or special mount options.

## Network files (`.network`)

```ini
[Network]

[Install]
WantedBy=default.target
```

Networks with `WantedBy=default.target` are auto-started. Use a separate network only when a pod needs isolation from `services.network` (e.g., `mssql.network`).
