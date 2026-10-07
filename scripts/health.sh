#!/usr/bin/env bash
# Ask a running mcl-echo how it is.
#
# /health is a Unix socket inside the container (mcl_om's health_socket), not a
# port, so this asks the running container itself. Pass the container's name if
# it is not mcl-echo; MCL_ENGINE picks podman over docker:
#
#   scripts/health.sh
#   MCL_ENGINE=podman scripts/health.sh my-mcl-echo
#
# THREE OUTCOMES, NOT TWO, because they need different responses from whoever is
# reading. Unreachable means the container is not running or not answering.
# Unhealthy means the node is up and telling you something is wrong with it, and
# mcl_om answers that with a 503 carrying a reason. Collapsing the two sends
# you to look in the wrong place.
#
#   0  healthy
#   1  reachable, reports degraded or down
#   2  unreachable

set -euo pipefail

CONTAINER="${1:-mcl-echo}"
ENGINE="${MCL_ENGINE:-docker}"
SOCKET=/run/mcl/health.sock
URL="${CONTAINER}:${SOCKET}"

# No -f, so a 503 arrives as a body to be shown rather than as a curl failure
# that hides the reason the service went to the trouble of reporting.
if ! RESPONSE="$("${ENGINE}" exec "${CONTAINER}" curl -sS --max-time 5 -w '\n%{http_code}' \
        --unix-socket "${SOCKET}" http://localhost/health 2>/dev/null)"; then
    echo "unreachable: ${URL}" >&2
    exit 2
fi

CODE="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"

# Pretty-print when python is around, otherwise show the raw body. A missing
# formatter must not turn a healthy node into a failed check.
if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${BODY}" | python3 -m json.tool 2>/dev/null || printf '%s\n' "${BODY}"
else
    printf '%s\n' "${BODY}"
fi

case "${CODE}" in
    200) exit 0 ;;
    "")  echo "no response from ${URL}" >&2 ; exit 2 ;;
    *)   echo "unhealthy (HTTP ${CODE}): ${URL}" >&2 ; exit 1 ;;
esac
