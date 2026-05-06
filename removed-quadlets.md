## Removed Quadlets

This journal tracks quadlet services that have been removed from the repository.
Each row records the last commit where the service files were available (parent of the deletion commit).

To restore a service, check out the files from the last commit:

```sh
git show <last-commit>:quadlets/<service>/ > quadlets/<service>/
```

| Service     | Date Removed | Last Commit | Notes                               |
|-------------|--------------|-------------|-------------------------------------|
| booklore    | 2026-03-23   | 89c7b1c     | replaced with grimmory              |
| calibre     | 2026-01-08   | 8004221     | replaced with booklore              |
| grimmory    | 2026-04-30   | 2dd9bc5     | replaced with calibre-web-automated |
| papra       | 2026-03-20   | d10875b     | replaced with paperless-ngx         |
| version-api | 2026-02-18   | 6b30fcb     | replaced with service-hub           |
