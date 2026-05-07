---
name: create-issue
description: Expand a request into a well-structured Forgejo issue — plan, ask clarifying questions, draft, and create via the fj CLI
---

## Overview

This skill covers taking a user's request and expanding it into a detailed, well-structured Forgejo issue that another agent (or the same one) can pick up and implement. Issues are created on `lgomes/home-services` using the `fj` CLI.

## Flow

### 1. Understand the request

Read the user's request carefully. Identify what they want done, which service(s) are involved, and any constraints.

### 2. Ask clarifying questions

If anything is ambiguous or underspecified, ask the user before proceeding. Key things to clarify:

- Which service or part of the repo is affected?
- Any specific version, config option, or behavior desired?
- Any constraints the user hasn't mentioned?
- Is there a deadline or priority?

Don't ask questions for the sake of it — only when genuinely needed to avoid a wrong approach.

### 3. Plan and expand

Expand the request into a detailed issue plan. Structure it so another agent can read it and start implementing without going back to the user:

**Title:** Concise, descriptive, kebab-case friendly. Prefer imperative mood (e.g., "Add health check to immich-server").

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

<Reference any relevant conventions from AGENTS.md — e.g., kebab-case, quadlet format, env file format, secrets handling>

## Acceptance criteria

- <Criterion 1>
- <Criterion 2>
```

### 4. Present draft to user

Show the draft title and body to the user. Ask if it looks correct or if they want any changes.

### 5. Create the issue

Once approved, create the issue on Forgejo:

```
fj issue create -R origin "<title>" --body "<body>"
```

**Important:** Carefully format the `--body` argument. For multi-line bodies, use newlines (the `fj` CLI supports them in quoted strings). Use GitHub-flavored markdown.

Report the created issue number and URL back to the user.

## Example

User says: "Add a health check to the immich-server container"

Agent:
1. Asks: "Any specific health check endpoint, or should I use the default `/server-info/health`?"
2. User confirms.
3. Draft:
   - Title: "Add health check to immich-server container"
   - Body with context, steps (add `HealthCmd`, `HealthInterval` to `.container` file), files involved, conventions, acceptance criteria
4. User approves.
5. Runs `fj issue create -R origin "Add health check to immich-server container" --body "..."`

## Implementation guidelines

- Follow all conventions in AGENTS.md (kebab-case, quadlet format, etc.)
- Use existing patterns from the codebase — look at similar files before drafting
- Never include real secrets or domain names in the issue body
- If the issue is about a new service, load the `add-service` skill for context

