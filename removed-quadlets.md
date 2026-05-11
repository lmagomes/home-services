## Removed Quadlets

This journal tracks quadlet services that have been removed from the repository.
Each row records the last commit where the service files were available (parent of the deletion commit).

To restore a service, check out the files from the last commit:

```sh
git show <last-commit>:quadlets/<service>/ > quadlets/<service>/
```

| Service             | Date Removed | Last Commit | Notes                                                                      |
|---------------------|--------------|-------------|----------------------------------------------------------------------------|
| booklore            | 2026-03-23   | 6d201e8     | replaced with grimmory                                                     |
| calibre             | 2026-01-08   | 8004221     | replaced with booklore                                                     |
| grimmory            | 2026-04-30   | efc048f     | replaced with calibre-web-automated                                        |
| papra               | 2026-03-20   | 65da666     | replaced with paperless-ngx                                                |
| version-api         | 2026-02-18   | 2edfeb7     | replaced with service-hub                                                  |
| youtube             | 2026-05-06   | 0c64974     | YouTube services (Invidious, Companion, DB, Materialious) no longer needed |
| lumo-tamer-browser  | 2026-05-07   | e68b4d1     | browser companion removed from llm pod                                     |
| ollama              | 2026-05-07   | 49ab130     | disabled files cleaned up                                                  |
| monitor-argus       | 2026-05-07   | c66a653     | replaced with Renovate                                                     |
| proton-drive-sync   | 2026-05-10   | 628e60f     | replaced by rclone for Proton Drive sync                                   |
