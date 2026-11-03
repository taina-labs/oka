#!/bin/sh
# Optional development helper. Normal deployments use the pinned published
# image from deploy/compose/compose.yaml.
set -eu

source_dir=${TAINA_SOURCE_DIR:-taina-src}
source_url=https://github.com/taina-labs/taina.git
image=${TAINA_IMAGE:-taina:local}
ref=${TAINA_REF:-main}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die "docker is required"
command -v git >/dev/null 2>&1 || die "git is required"

if [ -d "$source_dir/.git" ]; then
  git -C "$source_dir" fetch --quiet origin
  git -C "$source_dir" checkout --quiet "$ref"
  git -C "$source_dir" pull --quiet --ff-only origin "$ref" 2>/dev/null ||
    git -C "$source_dir" reset --quiet --hard "origin/$ref"
else
  [ ! -e "$source_dir" ] || die "$source_dir exists but is not a Git repository"
  git clone --quiet --branch "$ref" --depth 1 "$source_url" "$source_dir"
fi

docker build --tag "$image" "$source_dir"
printf '%s\n' "built $image"
printf '%s\n' "To test it, create deploy/compose/compose.yaml override with image: $image."
