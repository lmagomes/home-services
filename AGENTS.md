# AGENTS.md — Code Style & Conventions

This repository manages self-hosted services using **Podman Quadlets**, **systemd**, and **just** (command runner). All containers run rootless under a single user. Follow the conventions below when making changes.

## Project Layout

```
quadlets/<service>/        # Quadlet definitions (pods, containers, volumes, env)
justfiles/                 # Modular justfile recipes (imported by root justfile)
builds/<image>/            # Custom Containerfiles for locally-built images
timers/                    # Systemd timer + service units
.secrets/secrets.yaml      # SOPS-encrypted secrets (age key)
.forgejo/workflows/        # CI workflows (Forgejo Actions)
```

## Naming Conventions

### General

- Use **kebab-case** for all names: containers, pods, volumes, files, directories, and just recipes.
- Prefix container-specific resources with the service name (e.g., `paperless-postgres`, `dawarich-redis`).

### Files

| Type | Pattern | Example |
|------|---------|---------|
| Pod | `<service>.pod` | `caddy.pod` |
| Container | `<service>[-component].container` | `immich-server.container` |
| Volume | `<service>-<purpose>.volume` | `caddy-data.volume` |
| Network | `<name>.network` | `services.network` |
| Env directory | `<container-name>.service.d/` | `caddy.service.d/` |
| Env file | `<container-name>.service.d/env` | `caddy.service.d/env` |
| Extra config | `<container-name>.service.d/<file>` | `argus.service.d/config.yml` |
| Disabled files | append `.disabled` suffix | `ollama.container.disabled` |
| Just modules | `<domain>.just` | `backup.just` |
| Container builds | `builds/<image>/Containerfile` | `builds/caddy/Containerfile` |

### Quadlet directory structure

Each service lives in `quadlets/<service>/` and contains one `.pod` file, one or more `.container` files, zero or more `.volume` files, and a `.service.d/` directory per container that needs environment variables or config files.

## Quadlet File Format

All quadlet files use INI-style systemd unit syntax. Follow the section ordering and conventions below strictly.

### Pod files (`.pod`)

```ini
[Unit]
Description=<Service> pod managed by Podman
After=network-online.target

[Pod]
PodName=<service>.pod
Network=services.network
# PublishPort=<host>:<container>  (only if externally exposed)

[Install]
WantedBy=default.target
```

- `PodName` must end with `.pod`.
- Always include `Network=services.network` unless the pod has special networking needs.
- Only add `PublishPort` for services that need host-level port exposure (e.g., Caddy on 443).

### Container files (`.container`)

Section order: `[Unit]` → `[Container]` → `[Service]` → `[Install]`.

```ini
[Unit]
Description=<Component> container managed by Podman
After=network.target
# Requires=<dependency>.service    (if depends on other containers)
# After=<dependency>.service       (pair with Requires)

[Container]
Pod=<service>.pod
ContainerName=<container-name>
Image=<registry>/<image>:<version>
EnvironmentFile=./%n.d/env
# Secret=<secret-name>,type=env,target=<ENV_VAR>
# Volume=<volume-name>.volume:<mount-path>:Z
# Volume=./%n.d/<config-file>:<container-path>:ro,Z

[Service]
Restart=always                     # or on-failure

[Install]
WantedBy=multi-user.target         # or default.target
```

Key rules:
- `ContainerName` uses **kebab-case**.
- Pin image versions explicitly (e.g., `v2.6.2`, `18.1`). Avoid `:latest` for upstream images.
- Use `%n` (systemd specifier for the unit name) to reference the `.service.d/` directory: `EnvironmentFile=./%n.d/env`.
- Attach config files as read-only bind mounts: `Volume=./%n.d/<file>:<path>:ro,Z`.
- Attach named volumes with `:Z` for SELinux relabeling.
- Group related directives together: Secrets together, Volumes together.
- Place `HealthCmd`, `HealthInterval`, `HealthRetries`, etc. at the end of the `[Container]` section.
- For **s6-overlay / LSIO images** (those using `PUID`/`PGID`): set `PUID=0` and `PGID=0`. Do **not** use `UserNS=keep-id` — it breaks `s6-applyuidgid`. Rootless Podman already maps container root (UID 0) to the host user (UID 1000), so files are written with correct host ownership.
- Do **not** use `idmap` on bind mounts in rootless Podman — `mount_setattr` requires `CAP_SYS_ADMIN` and will fail with `OCI permission denied`.

### Volume files (`.volume`)

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

### Network files (`.network`)

```ini
[Network]

[Install]
WantedBy=default.target
```

## Environment Files

- Located at `<container-name>.service.d/env`.
- Use `KEY=value` format (no `export`, no quoting unless the value itself requires it).
- Comment out secrets that are injected via `Secret=` in the container file, documenting where they come from:
  ```
  #DATABASE_PASSWORD is set via Secret in the .container file
  ```
- Use `SCREAMING_SNAKE_CASE` for all environment variable names.

## Secrets

- All secrets are stored encrypted in `.secrets/secrets.yaml` using **SOPS** with an **age** key.
- Secrets are synced to Podman with `just sync-secrets`.
- Secret names use **kebab-case** (e.g., `paperless-db-password`, `domain-secret`).
- Reference secrets in container files with: `Secret=<name>,type=env,target=<ENV_VAR>`.
- Never commit plaintext secrets. The `.sops.yaml` at the repo root defines encryption rules.

## Justfiles

- The root `justfile` only contains imports and sets the shell to fish.
- All recipes live in `justfiles/<domain>.just` and are imported by the root justfile.
- Shell is **fish** — set globally via `set shell := ["/bin/fish", "-c"]`.
- Multi-line recipes use `#!/usr/bin/env fish` shebang.
- Recipe names use **kebab-case** (e.g., `sync-secrets`, `build-caddy`, `update-quadlet-pr`).
- Each file starts with a top-level comment describing its purpose.
- Each recipe has a comment above it describing what it does.
- Use emoji prefixes in output for visual clarity: `✅` success, `🔄` in-progress/restart, `🗑️` removal, `❗` warning, `⏭️` skip.
- Variables use **kebab-case**: `backup-dir`, `systemd-container-dir`.
- Justfile variables use `:=` with double-quoted values: `backup-dir := "$HOME/podman_volume_backup"`.

## Containerfiles (Custom Builds)

- Use file name `Containerfile` (not `Dockerfile`).
- Use multi-stage builds where applicable.
- Place in `builds/<image-name>/Containerfile`.
- Tag locally-built images as `localhost/<image-name>:<version>`.
- Extract the version from the base image when possible (via `sed` in the build recipe).

## Systemd Timers

- Timer and service unit files live in `timers/`.
- Timers use `OnCalendar=` for scheduling.
- The companion `.service` references the justfile with:
  ```ini
  ExecStart=/usr/bin/just --justfile %Y/../justfile <recipe>
  ```
  (`%Y` resolves to the directory of the original file, not the symlink.)

## CI / Forgejo Workflows

- Workflows live in `.forgejo/workflows/`.
- Use YAML format with standard GitHub Actions / Forgejo Actions syntax.
- Runner is `host` (runs directly on the host machine, not in a container).

## Version Management

- Container image versions are updated via `just update-quadlet-pr <quadlet> <container> <version>`.
- This creates a branch `updates/<quadlet>-<date>-<containers>`, commits the change, pushes, and opens a PR.
- When the PR is merged, the Forgejo workflow pulls images and restarts affected services.
- Release Argus monitors upstream releases and triggers Service-Hub webhooks to auto-create PRs.

## Migrations

When quadlet naming conventions or structure change, create a migration script in `migrations/`. Detailed conventions and workflow are in the `migrations` agent skill — load it with `/skill migrations` or by asking about migrations.

## Adding a New Service

1. Create `quadlets/<service>/` directory.
2. Add a `<service>.pod` file with the standard pod template.
3. Add `.container` files for each component, prefixed with the service name.
4. Add `.volume` files for persistent data.
5. Create `.service.d/env` files for each container that needs environment configuration.
6. Add secrets to `.secrets/secrets.yaml` (encrypted with `sops`), then run `just sync-secrets`.
7. If the service needs reverse proxying, add an entry to `caddy.service.d/Caddyfile`.
8. Run `just symlink-quadlets` and `systemctl --user daemon-reload`.
9. Optionally add the service to Release Argus and Service-Hub for automated updates.

Detailed conventions, templates, and common pitfalls are in the `add-service` agent skill — load it with `/skill add-service` or by asking about adding a new service.
