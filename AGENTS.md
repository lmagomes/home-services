# AGENTS.md — Code Style & Conventions

This repository manages self-hosted services using **Podman Quadlets**, **systemd**, and **just** (command runner). All containers run rootless under a single user. Issue tracking and PRs are on **Forgejo** (not GitHub) — use the `fj` CLI, not `gh`. Follow the conventions below when making changes.

## Project Layout

```
quadlets/<service>/        # Quadlet definitions (pods, containers, volumes, env, config)
justfiles/                 # Modular justfile recipes (imported by root justfile)
builds/<image>/            # Custom Containerfiles for locally-built images
timers/                    # Systemd timer + service units
.secrets/secrets.yaml      # SOPS-encrypted secrets (age key)
.sops.yaml                 # Age key reference for SOPS
.forgejo/workflows/        # CI workflows (Forgejo Actions)
```

## Naming Conventions

### General

- Use **kebab-case** for all names: containers, pods, volumes, files, directories, just recipes, and secret names.
- Prefix container-specific resources with the service name (e.g., `paperless-postgres`, `dawarich-redis`).

### Files

| Type | Pattern | Example |
|------|---------|---------|
| Pod | `<service>.pod` | `caddy.pod` |
| Container | `<service>[-component].container` | `immich-server.container` |
| Volume | `<service>-<purpose>.volume` | `caddy-data.volume` |
| Network | `<name>.network` | `services.network` |
| Env file | `<container-name>.env` | `caddy.env` |
| Extra config | `<container-name>-<file>` | `glance.yml` |
| Just modules | `<domain>.just` | `backup.just` |
| Container builds | `builds/<image>/Containerfile` | `builds/caddy/Containerfile` |

### Quadlet directory structure

Each service lives in `quadlets/<service>/` and contains one `.pod` file, one or more `.container` files, zero or more `.volume` files, and flat env/config files alongside the quadlet files.

## Quadlet File Format

All quadlet files use INI-style systemd unit syntax. Section order: `[Unit]` → type-specific → `[Service]` → `[Install]`.

Key rules:
- Pin image versions explicitly — no `:latest` or floating tags
- **Use `home-services/` as the image prefix** for all locally-built images (e.g., `Image=home-services/caddy-cloudflare-l4:2.11.2-alpine`). This is a Podman short-name alias that resolves to the Forgejo container registry. The alias config is generated at deploy time from the `registry-path` secret in `.secrets/secrets.yaml` by `just generate-registries-conf` (called automatically by `just install-quadlets`). Do NOT put the full registry domain in `Image=` directives — always use the `home-services/` alias.
- Use `EnvironmentFile=./%N.env` (`%N` expands to the unit name) for env files placed alongside the container. Use `Volume=./%N-<config-file>` for config files.
- For containers that share an env file, use an explicit filename (e.g., `EnvironmentFile=./immich.env`).
- Use `podman quadlet install` (via `just install-quadlets`) to deploy quadlet files to the systemd directory.
- Use `Secret=<name>,type=env,target=<ENV_VAR>` for secrets (not `PodmanArgs`)
- Named volumes use `:Z` for SELinux; bind mounts use `Mount=` with `relabel=private`
- `UserNS=keep-id` on pod files only, never for LSIO/s6 images
- LSIO images: `PUID=0`, `PGID=0` in env file
- Health checks go at the end of `[Container]`, before `[Service]`

Full templates, directive ordering, and detailed reference are in the `quadlet-reference` agent skill — load it with `/skill quadlet-reference` or by asking about quadlet files.

## Environment Files

- Located at `<container-name>.env`.
- Use `KEY=value` format (no `export`, no quoting unless the value itself contains spaces or special characters).
- Comment out secrets that are injected via `Secret=` in the container file, documenting where they come from:
  ```
  #DATABASE_PASSWORD is set via Secret in the .container file
  ```
- Use `SCREAMING_SNAKE_CASE` for all environment variable names.
- Commented-out variables with example values are acceptable as documentation:
  ```
  # OIDC_CLIENT_ID=<Client ID from authentik>
  # OIDC_CLIENT_SECRET=<Client secret from authentik>
  ```

## Secrets

- All secrets are stored encrypted in `.secrets/secrets.yaml` using **SOPS** with an **age** key.
- Secrets are synced to Podman with `just sync-secrets`.
- Secret names use **kebab-case** (e.g., `paperless-db-password`, `domain-secret`).
- Reference secrets in container files with: `Secret=<name>,type=env,target=<ENV_VAR>`.
- Never commit plaintext secrets. The `.sops.yaml` at the repo root defines encryption rules.

**Never read, write, decrypt, or edit `.secrets/secrets.yaml` or any temporary
decrypted copy of it.** If a task requires a new secret or updating an existing one,
tell the user the exact secret name needed (and which service/container it's for).
The user will add it themselves.

**Exception — encrypted quadlet configs (`*.encrypted.*`):** Unlike `.secrets/secrets.yaml`,
these files are safe for agents to decrypt with `sops` for review or editing. If changes are
made, re-encrypt the file back to its `.encrypted.*` form. Decrypt with:

```
sops decrypt <file>.encrypted.yml > <file>.yml     # review/edit
sops encrypt <file>.yml > <file>.encrypted.yml     # re-encrypt after edits
rm <file>.yml                                      # clean up decrypted copy
```

### Encrypted config `_unencrypted` convention

SOPS encrypted config files (`*.encrypted.*`) use SOPS's `unencrypted_suffix` feature
set to `_unencrypted`. This allows non-sensitive configuration values to be stored in
plaintext within the encrypted file so they are reviewable in PRs and `cat` output.

Rules:
- Append `_unencrypted` to keys whose values are **non-sensitive** (log levels,
  timeouts, paths, labels, cache settings, container options, volume mounts, etc.).
- Do **not** add `_unencrypted` to keys whose values are secrets (tokens, passwords,
  API keys, encryption keys, etc.) — those stay fully encrypted.
- sops v3.13+ strips the `_unencrypted` suffix automatically during decryption,
  producing a clean config file that the consuming application expects.
- To review an encrypted config: `cat` shows non-sensitive values in plaintext;
  use `sops decrypt` for the full picture including secrets.

Example — encrypted file content:
```yaml
server:
    url: ENC[AES256_GCM,data:...]          # secret — encrypted
    token: ENC[AES256_GCM,data:...]        # secret — encrypted
log:
    level_unencrypted: debug               # non-sensitive — readable
    job_level_unencrypted: info            # non-sensitive — readable
```

After `sops decrypt`:
```yaml
server:
    url: https://example.com
    token: abc123def456
log:
    level: debug
    job_level: info
```

## Domain Names

- Never include the real domain name in any tracked file.
- When a domain reference is needed in documentation, skills, or examples, use a placeholder like `example.com` or `your-domain.com`.
- If a task requires referencing the real domain and a placeholder cannot work (e.g., an encrypted config file), inform the user rather than writing the real domain.

## Justfiles

- The root `justfile` only contains imports and sets the shell to fish.
- All recipes live in `justfiles/<domain>.just` and are imported by the root justfile.
- Shell is **fish** — set globally via `set shell := ["/bin/fish", "-c"]`.
- Multi-line recipes use `#!/usr/bin/env fish` shebang.
- Recipe names use **kebab-case** (e.g., `sync-secrets`, `build-caddy`, `update-quadlet-pr`).
- Each file starts with a top-level comment describing its purpose.
- Each recipe has a comment above it describing what it does.
- Use emoji prefixes in output for visual clarity: `✅` success, `🔄` in-progress/restart, `🗑️` removal, `❗` warning, `⏭️` skip, `❌` error.
- Variables use **kebab-case**: `backup-dir`, `systemd-container-dir`.
- Justfile variables use `:=` with double-quoted values: `backup-dir := "$HOME/podman_volume_backup"`.

## Containerfiles (Custom Builds)

- Use file name `Containerfile` (not `Dockerfile`).
- Use multi-stage builds where applicable.
- Place in `builds/<image-name>/Containerfile`.
- Tag locally-built images as `localhost/<image-name>:<version>`.
- Extract the version from the base image's `FROM` line when possible (via `sed` in the build recipe).
- Avoid tagging locally-built images as `:latest` — always include a version. Images referenced in `.container` files must have pinned versions.

## Systemd Timers

- Timer and service unit files live in `timers/`.
- Timers use descriptive names (e.g., `backup.timer`, `backup.service`).
- Timers use `OnCalendar=` for scheduling.
- The companion `.service` references the justfile with:
  ```ini
  ExecStart=/usr/bin/just --justfile %Y/../justfile <recipe>
  ```
  (`%Y` resolves to the directory of the original file, not the symlink.)

## CI / Forgejo Workflows

- Workflows live in `.forgejo/workflows/`.
- Use YAML format with standard Forgejo Actions / GitHub Actions syntax.
- Runner is `host` (runs directly on the host machine, not in a container).
- The CI workflow triggers on merged PRs whose branch starts with `updates/`.

## Version Management

- Container image versions are updated via `just update-quadlet-pr <quadlet> <container> <version>`.
- This creates a branch `updates/<quadlet>-<date>-<containers>`, commits the change, pushes, and opens a PR.
- When the PR is merged, the Forgejo workflow pulls images and restarts affected services via `just update-podman-images`.
- Renovate monitors upstream releases and triggers Service-Hub webhooks to auto-create PRs.

## Adding a New Service

Detailed checklist, templates, and common pitfalls are in the `add-service` agent skill — load it with `/skill add-service` or by asking about adding a new service.

## Working on Issues

Issues and pull requests are tracked on **Forgejo** (not GitHub). Use the `fj` CLI for all issue and PR operations — never use GitHub CLI (`gh`).

Detailed workflow (listing, viewing, branching, committing, pushing, PR creation) is in the `forgejo-issue` agent skill — load it with `/skill forgejo-issue` or by asking about issues or working on an issue.

To expand a request into a new issue, use the `create-issue` skill — load it with `/skill create-issue` or by asking to create an issue.
