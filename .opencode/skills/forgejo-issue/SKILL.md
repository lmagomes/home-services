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

### Implementation

1. Read the issue body and all comments to fully understand the request
2. Create a new branch from main with a `feature/` prefix. Use a kebab-case name that describes the change, incorporating the issue ID when available:
   ```
   git checkout main && git pull && git checkout -b feature/issue-<id>-<short-description>
   ```
3. Plan the implementation based on the repository conventions (see AGENTS.md)
4. Implement the changes
5. Verify with any available tests or linting

### After the work is done

6. Commit the changes with a concise message following the repo's commit style:
   ```
   git add -A && git commit -m "<type>: <description>"
   ```
7. Push the branch to Forgejo:
   ```
   git push -u origin feature/issue-<id>-<short-description>
   ```
8. Create a pull request. Include `Closes #<id>` in the PR body so the issue is automatically closed when the PR is merged. Use `--autofill` when there is a single commit, or provide `--title` and `--body` explicitly:
   ```
   fj pr create -R origin --head feature/issue-<id>-<short-description> --base main --title "..." --body "Closes #<id>

   <description of changes>"
   ```
9. If the changes introduced new secrets, add a comment on the PR listing exactly what secrets the user needs to add to `.secrets/secrets.yaml`:
   ```
   fj pr comment <pr-number> -R origin -m "..."
   ```
   Otherwise, comment on the original issue with a summary of the work done:
   ```
   fj issue comment <id> -R origin -m "..."
   ```
10. Checkout back to main and clean up:
    ```
    git checkout main
    ```

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
- If the issue requires a migration, load the `migrations` skill
