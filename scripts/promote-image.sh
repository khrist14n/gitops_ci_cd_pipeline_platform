#!/usr/bin/env bash
# promote-image.sh <app> <env> [image-ref]
#
# GitOps-native promotion: pin a freshly built image (digest or tag) into the
# environment overlay `gitops/environments/<env>.yaml` on a promotion branch.
# Merging that branch is the ONLY way the desired state changes, so git history
# doubles as the deployment audit trail.
#
#   image-ref   Registry digest (preferred) or tag. Defaults to the short SHA
#               of HEAD if omitted.
#
# Exit codes: 0 ok, 1 usage, 2 image-not-found, 3 conflict/non-clean branch.
set -euo pipefail

APP="${1:-}"
ENV_NAME="${2:-}"
IMAGE_REF="${3:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/gitops/environments/$ENV_NAME.yaml"
BRANCH="promotion/$APP-$ENV_NAME"

if [[ -z "$APP" || -z "$ENV_NAME" ]]; then
  echo "usage: promote-image.sh <app> <env> [image-ref]" >&2
  exit 1
fi
[[ -f "$OVERLAY" ]] || { echo "environment overlay not found: $OVERLAY" >&2; exit 1; }

if [[ -z "$IMAGE_REF" ]]; then
  IMAGE_REF="${GITHUB_SHA:-$(git rev-parse HEAD)}"
fi

IMAGE_REF="$(echo "$IMAGE_REF" | tr '[:upper:]' '[:lower:]')"

# Create/update the promotion branch from main (tolerate missing origin locally).
git fetch origin main --quiet 2>/dev/null || true
git checkout -B "$BRANCH" "origin/main" >/dev/null 2>&1 || git checkout -B "$BRANCH" main >/dev/null

python3 - "$OVERLAY" "$IMAGE_REF" <<'PY'
import sys
import yaml

path, ref = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = yaml.safe_load(fh) or {}

image = doc.setdefault("image", {})
if "@" in ref and "sha256:" in ref:  # digest pins are preferred (immutable)
    image["digest"] = ref.split("@", 1)[1]
    image.pop("tag", None)
else:
    image["tag"] = ref
    image.pop("digest", None)

with open(path, "w") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY

git add "gitops/environments/$ENV_NAME.yaml"
if ! git diff --cached --quiet; then
  git -c user.name="gitops-promotion-bot" \
      -c user.email="gitops-bot@users.noreply.github.com" \
      commit -m "promote ${APP}: pin image ${IMAGE_REF} to ${ENV_NAME}" >/dev/null
else
  echo "no change -- ${IMAGE_REF} already pinned for ${ENV_NAME}" >&2
fi

echo "promotion branch: $BRANCH"
echo "image: $(python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1]))["image"]; print((d["repository"]+"@"+d["digest"]) if d.get("digest") else (d["repository"]+":"+d["tag"]))' "$OVERLAY")"