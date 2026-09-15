---
name: ship-issue
description: End-to-end Forgejo workflow — turn a request into a well-structured issue, implement it on a feature branch, and open a PR that closes it. Use when the user asks to work on something directly, e.g. "work on X and open a PR", "ship X", "implement X end-to-end", or when they do not want to file the issue themselves first.
---

## Overview

This skill merges `create-issue` and `forgejo-issue` into one flow: take the user's request, expand it into a Forgejo issue, create that issue, then immediately do the work on a branch and open a PR that closes it.

Use this when the user wants a request implemented end-to-end. Use `create-issue` on its own when they only want an issue filed, and `forgejo-issue` on its own when the issue already exists.

There is exactly **one approval checkpoint**: after the issue draft is ready, before creating it. Everything after that (create issue → implement → push → PR) runs without further pauses, unless you need to ask a clarifying question.

Issues and PRs target `lgomes/home-services` via `-R origin`.

## Flow

### 1. Understand the request

Read the request carefully. Identify what should change, which service(s) are involved, and any constraints.

### 2. Ask clarifying questions

If anything is ambiguous or underspecified, ask before proceeding. Only ask when genuinely needed to avoid a wrong approach:

- Which service or part of the repo is affected?
- Any specific version, config option, or behavior desired?
- Any constraints the user hasn't mentioned?
- Is there a deadline or priority?

### 3. Plan and draft the issue

Expand the request into a detailed issue that another agent could also pick up. Look at similar files in the repo first so the plan matches existing patterns.

**Title:** Concise and descriptive. Prefer imperative mood (e.g., "Add health check to immich-server").

**Body — use this template:**

```
## Context

<Brief background: what service/area is affected, why this change is needed>

## What needs to be done

1. <Step 1>
2. <Step 2>
...

## Files likely involved

- `path/to/file`
- `path/to/other/file`

## Conventions to follow

<Relevant conventions from AGENTS.md — kebab-case, quadlet format, env file format, secrets handling>

## Acceptance criteria

- <Criterion 1>
- <Criterion 2>
```

### 4. Present the draft and wait for approval

Show the draft title and body. Ask the user to confirm or request changes. **Do not create the issue or start implementing until they approve.** This is the only mandatory pause.

### 5. Create the issue

Once approved:

```
fj issue create -R origin "<title>" --body "<body>"
```

Capture the issue number from the returned URL and use it for the branch name and PR body.

### 6. Set up an isolated workspace

Clone to a temp directory so parallel agents don't collide on the working tree:

```
git clone "$(git remote get-url origin)" /tmp/opencode-<id>
workdir=/tmp/opencode-<id>
git checkout main && git pull && git checkout -b feature/issue-<id>-<short-description>
```

All subsequent file operations use paths under `/tmp/opencode-<id>/`.

### 7. Implement and verify

Implement the changes following repo conventions (see AGENTS.md). Verify with any available tests or linting.

### 8. Commit and push

Commit with a concise message in the repo's style, then push:

```
workdir=/tmp/opencode-<id>
git add -A && git commit -m "<type>: <description>"
git push -u origin feature/issue-<id>-<short-description>
```

### 9. Open the PR

Include `Closes #<id>` in the body so the issue closes automatically on merge:

```
fj pr create -R origin --head feature/issue-<id>-<short-description> --base main --title "..." --body "Closes #<id>

<description of changes>"
```

Use `--autofill` when there is a single commit.

### 10. Comment

- If the work needs new secrets, comment on the PR listing exactly what the user must add to `.secrets/secrets.yaml`:

  ```
  fj pr comment <pr-number> -R origin -m "..."
  ```

- Otherwise, comment on the issue with a short summary of the work:

  ```
  fj issue comment <id> -R origin -m "..."
  ```

### 11. After the PR is merged

When the user confirms the PR is merged, clean up:

```
rm -rf /tmp/opencode-<id>
```

## Container environment note

**Never install, deploy, restart services, or run quadlet/timer installation commands during development.** The agent runs inside a container without access to the host systemd or Podman. Work is limited to file changes, commits, pushes, and PR creation. Deployment happens via CI after the PR is merged, or manually by the user on the host.

## Implementation guidelines

- Follow all conventions in AGENTS.md (kebab-case, quadlet format, env file format, etc.)
- Use existing patterns from the codebase — look at similar files before writing new ones
- Never read, write, or decrypt `.secrets/secrets.yaml` — ask the user to handle secrets
- Never include real secrets or domain names in issue or PR bodies
- For encrypted quadlet configs (`*.encrypted.yml`), use `sops decrypt` / `sops encrypt`
- If the request adds a new service, load the `add-service` skill for detailed guidance
- If only the issue needs writing (no implementation), use the `create-issue` skill instead
