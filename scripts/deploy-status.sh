#!/usr/bin/env bash
# deploy-status.sh <app> <env>  — report sync + health state of an ArgoCD app.
set -euo pipefail

APP="${1:-}"
ENV_NAME="${2:-}"
APP_NAME="${APP}-${ENV_NAME}"
ARGO_SERVER="${ARGOCD_SERVER:-argocd.example.com}"

if ! command -v argocd >/dev/null 2>&1; then
  echo "argocd CLI required (export ARGOCD_AUTH_TOKEN or use `kubectl exec` port-forward)" >&2
  exit 2
fi

argocd app get "$APP_NAME" \
  --server "$ARGO_SERVER" \
  -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"app:            {d[\"metadata\"][\"name\"]}")
print(f"sync status:    {d[\"status\"][\"sync\"][\"status\"]}")
print(f"health:         {d[\"status\"][\"health\"][\"status\"]}")
print(f"revision:       {d[\"status\"][\"sync\"][\"revision\"]}")
print(f"image:          {d[\"status\"][\"summary\"][\"images\"][0] if d.get(\"status\",{}).get(\"summary\",{}).get(\"images\") else \"n/a\"}")
print(f"resources:      {d[\"status\"].get(\"resources\", [])}")
'