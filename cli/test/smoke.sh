#!/bin/sh
# End-to-end smoke for the taina CLI against a real docker container.
#
# Needs: docker. Uses the published image by default; point TAINA_IMAGE at a
# locally built one to test the source. Run by hand from the repo root; CI does
# not run it (CI only builds and runs the unit tests).
#
#   cli/test/smoke.sh
#
# The CLI creates the container itself (`taina setup`), so there is no compose
# file and no hand-written `docker run` here.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$root/cli/zig-out/bin/taina"
work="$(mktemp -d)"
container="taina-smoke-$$"
image="${TAINA_IMAGE:-ghcr.io/taina-labs/taina:latest}"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true; docker network rm "$TAINA_NETWORK" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

command -v docker >/dev/null 2>&1 || { echo "smoke needs docker"; exit 1; }
docker info >/dev/null 2>&1 || { echo "smoke needs docker running"; exit 1; }
[ -x "$cli" ] || { echo "smoke needs the CLI built: (cd cli && zig build)"; exit 1; }

# Everything lives under $work, so the smoke leaves nothing behind but the
# pulled image.
export TAINA_BACKEND=docker
export TAINA_CONTAINER="$container"
export TAINA_NETWORK="taina-smoke-$$"
export TAINA_IMAGE="$image"
export TAINA_CONFIG="$work/taina.conf"
export TAINA_DB_DIR="$work/db"
export TAINA_STORAGE_DIR="$work/storage"
export TAINA_BACKUP_DIR="$work/backups"
export TAINA_HOST_PORT=4400
mkdir -p "$TAINA_DB_DIR" "$TAINA_STORAGE_DIR" "$TAINA_BACKUP_DIR"

echo '==> setup'
"$cli" setup
echo '==> status'
"$cli" status
echo '==> logs'
"$cli" logs --tail 5
echo '==> doctor'
"$cli" doctor
echo '==> backup'
"$cli" backup --out "$TAINA_BACKUP_DIR"
echo '==> down'
"$cli" down
echo '==> up'
"$cli" up
echo '==> update'
"$cli" update
echo "smoke ok"
