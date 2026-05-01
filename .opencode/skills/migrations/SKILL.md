---
name: migrations
description: Guidelines for creating and applying data migration scripts when quadlet naming conventions or structure change
---

## Overview

When quadlet naming conventions or structure change, you may need a data migration so existing installations don't lose data. Migration scripts live in `migrations/` and are applied via `just apply-migrations`.

## File format

```
migrations/YYYYMMDDHHMMSS-<description>.fish
```

- The 14-digit timestamp ensures ordering
- Description uses **kebab-case**
- Scripts are **fish** (`#!/usr/bin/env fish`)
- Each script must be **idempotent** — safe to run multiple times

## Idempotency rules

Every migration must check real state before acting:

- If the old state doesn't exist → skip (nothing to migrate)
- If the new state already exists → skip (already applied)
- Only perform the migration when old exists AND new doesn't

This means losing the state file is safe — re-running won't break anything.

## State tracking

State file: `~/.config/containers/systemd/.quadlet-migrations`

- One migration ID per line (the script filename without `.fish`)
- **Not committed** to git — each machine tracks its own applied migrations
- Managed automatically by `just apply-migrations`

## Applying migrations

```bash
just apply-migrations
```

This does, in order:
1. Scans `migrations/*.fish` sorted by datetime prefix
2. Skips any with IDs already in the state file
3. Runs each unapplied script in order
4. On success, appends the ID to the state file
5. Runs `just symlink-quadlets` + `systemctl --user daemon-reload`

If any migration fails, the process aborts immediately (failed migrations are NOT marked as applied).

## Writing a new migration

1. Create `migrations/YYYYMMDDHHMMSS-<description>.fish`
2. Add `#!/usr/bin/env fish` shebang
3. Check old state → only migrate when needed
4. Skip if new state already exists
5. Use `echo` with emoji for progress: 🔄 in-progress, ✅ success, ⏭️ skip, ❌ failure
6. Exit non-zero on failure

## Example structure

```fish
#!/usr/bin/env fish
# Description of what this migration does

echo "🔄 Checking for old state..."

# Check if migration is even needed
if not <old-state-exists-check>
    echo "⏭️  Nothing to migrate"
    exit 0
end

# Check if already done (idempotent)
if <new-state-exists-check>
    echo "⏭️  Already migrated"
    exit 0
end

# Perform migration
echo "🔄 Migrating..."
<do-the-work>

echo "✅ Migration complete"
```
