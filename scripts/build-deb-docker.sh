#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
platform=${DEB_PLATFORM:-linux/amd64}
image=${DEB_IMAGE:-ubuntu:22.04}
version=${VERSION:-1.0.4}

command -v docker >/dev/null 2>&1 || {
  printf 'ERROR: Docker is required for make deb-docker\n' >&2
  exit 1
}

case "$platform" in
  linux/amd64|linux/arm64) ;;
  *)
    printf 'ERROR: DEB_PLATFORM must be linux/amd64 or linux/arm64\n' >&2
    exit 1
    ;;
esac

printf 'Building %s Debian package in %s for %s\n' \
  "$version" "$image" "$platform"

docker run --rm \
  --platform "$platform" \
  -e "VERSION=$version" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  -v "$project_root:/src" \
  -w /src \
  "$image" \
  sh -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential \
      cups-client \
      dpkg-dev \
      libcups2-dev \
      libcupsimage2-dev \
      python3
    make clean
    make deb VERSION="$VERSION"
    make clean
    chown -R "$HOST_UID:$HOST_GID" /src/build /src/dist 2>/dev/null || true
  '
