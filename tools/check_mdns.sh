#!/usr/bin/env bash
# tools/check_mdns.sh
# Quick macOS script to verify daemon mDNS advertisement and HTTP endpoints.

set -euo pipefail

PORT=${1:-9595}
SERVICE_NAME=${2:-codexmeter}

echo "Checking mDNS for _http._tcp local..."
# List services
dns-sd -B _http._tcp local &
BSD_PID=$!
sleep 1
# Try to resolve the specific service name
echo "Resolving service ${SERVICE_NAME}..."
dns-sd -L "${SERVICE_NAME}" _http._tcp local || true
sleep 1
kill ${BSD_PID} 2>/dev/null || true

# Try HTTP endpoints
HOST=${3:-localhost}
URL="http://${HOST}:${PORT}"
echo "Testing HTTP endpoints at ${URL}"
for path in usage status; do
  echo -n "GET ${path} -> "
  if curl -fsS --max-time 5 "${URL}/${path}" -w '\nHTTP %{http_code}\n' -o /dev/stderr; then
    echo "OK"
  else
    echo "FAILED"
  fi
done

echo "Done."