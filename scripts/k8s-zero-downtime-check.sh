#!/usr/bin/env bash
#
# Hits the app through the Ingress ~10x/second and reports any non-200 response.
# Run it in one terminal while performing a rolling update / rollback in another.
set -euo pipefail

URL="${1:-http://app.localtest.me/}"
DURATION="${2:-60}"
ok=0
fail=0
end=$((SECONDS + DURATION))
while [[ "${SECONDS}" -lt "${end}" ]]; do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "${URL}" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    echo "$(date -u +%T) non-200 response: ${code}"
  fi
  sleep 0.1
done
echo "requests ok=${ok} failed=${fail}"
[[ "${fail}" -eq 0 ]]
