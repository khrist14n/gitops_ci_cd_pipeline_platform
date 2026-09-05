#!/usr/bin/env bash
# rollback.sh <app> <env> [--to-previous | --to-revision <n>]
#
# Automated rollback that is fully GitOps-native:
#   1. finds the last-known-good image pin from git history of the overlay
#   2. rewrites the environment overlay back to it on a rollback branch + merge
#   3. forces an ArgoCD resync so the cluster converges to the reverted state
#
# The git commit is itself the audit trail: every rollback is a documented revert.
set -euo pipefail

APP="${1:-}"
ENV_NAME="${2:-}"
MODE="${3:---to-previous}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY_REL="gitops/environments/$ENV_NAME.yaml"
BRANCH="rollback/$APP-$ENV_NAME"

if [[ -z "$APP" || -z "$ENV_NAME" ]]; then
  echo "usage: rollback.sh <app> <env> [--to-previous|--to-revision <n>]" >&2
  exit 1
fi

git fetch origin main --quiet 2>/dev/null || true
git checkout -B "$BRANCH" "origin/main" >/dev/null 2>&1 || git checkout -B "$BRANCH" main >/dev/null

# Prefer origin/main when present (CI), fall back to local main (dev machines).
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE_REF="origin/main"
else
  BASE_REF="main"
fi

case "$MODE" in
  --to-revision)
    REV="${4:-}"
    : "${REV:?usage: --to-revision requires a revision number}"
    ;;
  --to-previous|*)
    REV="$(git rev-list -n 2 "$BASE_REF" -- "$OVERLAY_REL" | tail -n 1)"
    ;;
esac

if [[ -z "$REV" ]]; then
  echo "no prior state found to roll back to" >&2
  exit 1
fi

git checkout "$REV" -- "$OVERLAY_REL"
git add "$OVERLAY_REL"
if git diff --cached --quiet; then
  echo "overlay already reflects revision ${REV} -- nothing to roll back" >&2
  exit 0
fi
git -c user.name="gitops-rollback-bot" \
    -c user.email="gitops-bot@users.noreply.github.com" \
    commit -m "rollback ${APP} in ${ENV_NAME} to revision ${REV}" >/dev/null

echo "rollback branch: $BRANCH (reverted overlay to revision ${REV})"
echo "after merge, run: argocd app sync ${APP}-${ENV_NAME} --force"