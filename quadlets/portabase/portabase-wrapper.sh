#!/bin/bash
# Add `--behind-proxy` as a workaround. It may not be required in the future: https://github.com/Portabase/portabase/issues/279
sed \
  -e 's|tusd --base-path|tusd --behind-proxy --base-path|' \
  -e 's|PORT=3000 node|PORT=3000 HOSTNAME=0.0.0.0 node|' \
  /app/app-prod-entrypoint.sh > /tmp/patched-entrypoint.sh
exec bash /tmp/patched-entrypoint.sh
