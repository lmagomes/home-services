---
name: forgejo-issue
description: Work with Forgejo issues from this repository using the fj CLI — list open issues, view details, implement fixes, and create PRs
---

## Overview

This skill covers viewing, listing, and working on Forgejo issues for `lgomes/home-services`. The `fj` CLI is authenticated and ready to use. All issue operations target this repository by using `-R origin` (the local git remote).

## Listing issues

When the user asks to see open issues, use:

```
fj issue search -R origin -s open
```

For a specific query:

```
fj issue search -R origin -s open <query>
```

Present the results as a numbered list with the issue ID, title, and state. Ask the user which one to work on.

## Viewing an issue

When the user specifies an issue ID, view the full issue including comments:

```
fj issue view <id> -R origin       # title + body
fj issue view <id> -R origin comments  # all comments
```

Read the body thoroughly to understand what needs to be done. Check the comments for any additional context, decisions, or partial work.

## Working on an issue

### Setup: clone to isolated workspace

1. Read the issue body and all comments to fully understand the request
2. Clone the repository to a temporary working directory so multiple agents can work in parallel without branch conflicts:
   ```
   git clone "$(git remote get-url origin)" /tmp/opencode-<issue-id>
   ```
3. In the temp clone, create a new branch from main with a `feature/` prefix. Use a kebab-case name that describes the change, incorporating the issue ID when available:
   ```
   workdir=/tmp/opencode-<issue-id>
   git checkout main && git pull && git checkout -b feature/issue-<id>-<short-description>
   ```
4. Plan the implementation based on the repository conventions (see AGENTS.md)
5. Implement the changes in the temp clone (all file operations use paths under `/tmp/opencode-<issue-id>/`)
6. Verify with any available tests or linting

### After the work is done

7. Commit the changes with a concise message following the repo's commit style:
   ```
   workdir=/tmp/opencode-<issue-id>
   git add -A && git commit -m "<type>: <description>"
   ```
8. Push the branch to Forgejo:
   ```
   workdir=/tmp/opencode-<issue-id>
   git push -u origin feature/issue-<id>-<short-description>
   ```
9. Create a pull request. Include `Closes #<id>` in the PR body so the issue is automatically closed when the PR is merged. Use `--autofill` when there is a single commit, or provide `--title` and `--body` explicitly:
   ```
   fj pr create -R origin --head feature/issue-<id>-<short-description> --base main --title "..." --body "Closes #<id>

   <description of changes>"
   ```
10. If the changes introduced new secrets, add a comment on the PR listing exactly what secrets the user needs to add to `.secrets/secrets.yaml`:
    ```
    fj pr comment <pr-number> -R origin -m "..."
    ```
    Otherwise, comment on the original issue with a summary of the work done:
    ```
    fj issue comment <id> -R origin -m "..."
    ```

### After the PR is merged

11. When the user confirms the PR has been merged, clean up the temp clone:
    ```
    rm -rf /tmp/opencode-<issue-id>
    ```

### Container environment note

**Never install, deploy, restart services, or run quadlet/timer installation commands during development.** The agent runs inside a container and does not have access to the host systemd or Podman. Development is strictly limited to file changes, commits, pushes, and PR creation. Deployment happens via CI after the PR is merged, or manually by the user on the host.

## Commenting on an issue

```
fj issue comment <id> -R origin -m "message"
```

Keep comments concise and focused on the work done.

## Implementation guidelines

- Follow all conventions in AGENTS.md (kebab-case, quadlet format, etc.)
- Use existing patterns from the codebase — look at similar files before writing new ones
- Never read, write, or decrypt `.secrets/secrets.yaml` — ask the user to handle secrets
- For encrypted quadlet configs (`*.encrypted.yml`), use `sops decrypt` / `sops encrypt`
- If the issue requires a new service, load the `add-service` skill for detailed guidance

