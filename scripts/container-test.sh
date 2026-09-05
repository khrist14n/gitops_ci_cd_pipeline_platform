#!/usr/bin/env bash
# container-test.sh [build|test] — build the dev image (with dev extras) and run
# pytest inside the container, using podman or docker.
#
#   ./scripts/container-test.sh build   # build image target `dev`
#   ./scripts/container-test.sh test    # build (cached) + run pytest (default)
#
# The engine is auto-detected (podman preferred, docker fallback); force one with
# the CONTAINER_ENGINE env var, e.g. `CONTAINER_ENGINE=podman` (rootless works).
#
# Exit codes: 0 ok, 1 no engine found, 2 usage.
set -euo pipefail

ACTION="${1:-test}"
case "$ACTION" in
  build|test) ;;
  *) echo "usage: $0 [build|test]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="demo-app"
APP_DIR="$ROOT/apps/$APP"
IMAGE_TAG="${IMAGE_TAG:-${APP}:dev}"

ENGINE="${CONTAINER_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  if command -v podman >/dev/null 2>&1; then
    ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
  else
    echo "error: neither podman nor docker found (set CONTAINER_ENGINE to force one)" >&2
    exit 1
  fi
fi

echo "== [$ENGINE] build image target 'dev' as $IMAGE_TAG =="
"$ENGINE" build --target dev -t "$IMAGE_TAG" "$APP_DIR"

if [[ "$ACTION" == "build" ]]; then
  exit 0
fi

echo "== [$ENGINE] run pytest in $IMAGE_TAG =="
# Mount src/tests read-only so local edits are exercised without rebuilding.
exec "$ENGINE" run --rm \
  -v "$APP_DIR/src:/app/src:ro" \
  -v "$APP_DIR/tests:/app/tests:ro" \
  "$IMAGE_TAG" python -m pytest tests -q