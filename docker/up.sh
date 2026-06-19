#!/usr/bin/env bash
set -e

cat > "$(dirname "$0")/.env" <<EOF
HOST_USER=${USER}
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF

docker compose up -d "$@"
