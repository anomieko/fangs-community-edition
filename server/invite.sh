#!/usr/bin/env bash
# Prints the invite code for the public launcher (GitHub Releases build, nothing baked in): players paste it on
# the first start. It holds the server address and the join code, so share it like the join code (privately).
#   FANGS_JOIN_CODE=$(cat work/joincode) server/invite.sh <public-host>[:port]   (port defaults to 8080)
set -euo pipefail
host=${1:?usage: FANGS_JOIN_CODE=... server/invite.sh <public-host>[:port]}
[[ $host == *:* ]] || host=$host:8080
code=${FANGS_JOIN_CODE:?set FANGS_JOIN_CODE}
printf 'FCE-%s\n' "$(printf '%s/%s' "$host" "$code" | base32 -w0 | tr -d '=')"
