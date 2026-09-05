#!/usr/bin/env bash
# run-tests.sh — run the full local test surface for this platform.
#
#   ./scripts/run-tests.sh            # run everything
#   ./scripts/run-tests.sh --app-only # app unit tests + ruff + chart lint only
#
# Every phase reports PASS | SKIP | FAIL and exit code reflects failures.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
SKIP=0
APP_ONLY=0
[[ "${1:-}" == "--app-only" ]] && APP_ONLY=1

have() { command -v "$1" >/dev/null 2>&1; }
report() { # report <state> <msg>
  local state="$1"; shift
  case "$state" in
    pass) PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$*" ;;
    fail) FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$*" ;;
    skip) SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$*" ;;
  esac
}
section() { printf '\n== %s ==\n' "$*"; }

# ----------------------------------------------------------------------------
section "1. Application unit tests"
if have python3; then
  VENV="$ROOT/.venv"
  if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV" 2>/dev/null || report fail "create venv"
  fi
  if "$VENV/bin/python" -m pip install -q -r apps/demo-app/requirements-dev.txt 2>/dev/null; then
    if (cd apps/demo-app && "$VENV/bin/python" -m pytest tests -q >/tmp/opencode-test-app.log 2>&1); then
      report pass "demo-app unit tests"
    else
      report fail "demo-app unit tests (see /tmp/opencode-test-app.log)"
    fi
  else
    report skip "pip install unavailable in venv"
  fi
else
  report skip "python3 not installed"
fi

if (( APP_ONLY )); then
  echo
  echo "== summary: pass=$PASS fail=$FAIL skip=$SKIP =="
  exit $(( FAIL ? 1 : 0 ))
fi

# ----------------------------------------------------------------------------
section "2. Lint (ruff) + format check"
RUFF="$(command -v ruff || true)"
[[ -z "$RUFF" && -x "$ROOT/.venv/bin/ruff" ]] && RUFF="$ROOT/.venv/bin/ruff"
if [[ -n "$RUFF" ]]; then
  if "$RUFF" check apps/demo-app >/tmp/opencode-test-ruff.log 2>&1 \
     && "$RUFF" format --check apps/demo-app >>/tmp/opencode-test-ruff.log 2>&1; then
    report pass "ruff check + ruff format --check"
  else
    report fail "ruff (see /tmp/opencode-test-ruff.log)"
  fi
else
  report skip "ruff not installed (install via apps/demo-app/requirements-dev.txt)"
fi

# ----------------------------------------------------------------------------
section "3. Helm chart lint"
if have helm; then
  helm lint charts/demo-app >/tmp/opencode-test-helm.log 2>&1 \
    && report pass "helm lint charts/demo-app" \
    || report fail "helm lint charts/demo-app (see /tmp/opencode-test-helm.log)"
else
  report skip "helm CLI not installed (see docs/testing.md)"
fi

# ----------------------------------------------------------------------------
section "4. Helm render (chart x environment) + k8s object validation"
if have helm && have python3; then
  ok=1
  for env in dev staging prod; do
    if ! helm template "demo-app" charts/demo-app \
         -f "gitops/environments/$env.yaml" \
         --set-string image.repository=ghcr.io/example/demo-app 2>/dev/null \
      | python3 -c 'import sys,yaml; docs=[d for d in yaml.safe_load_all(sys.stdin) if d]; assert docs and all(d.get("apiVersion") and d.get("kind") for d in docs)' 2>/dev/null; then
      ok=0
      report fail "helm render gitops/environments/$env.yaml"
    fi
  done
  (( ok )) && report pass "helm render all environments (dev/staging/prod)"

  # New Relic env vars must appear only where telemetry.enabled (staging/prod),
  # while dev stays clean. Guards against accidental over-injection.
  if helm template "demo-app" charts/demo-app -f gitops/environments/staging.yaml --set-string image.repository=ghcr.io/example/demo-app 2>/dev/null \
     | grep -q 'NEW_RELIC_LICENSE_KEY' \
     && helm template "demo-app" charts/demo-app -f gitops/environments/prod.yaml --set-string image.repository=ghcr.io/example/demo-app 2>/dev/null \
     | grep -q 'NEW_RELIC_LICENSE_KEY' \
     && ! helm template "demo-app" charts/demo-app -f gitops/environments/dev.yaml --set-string image.repository=ghcr.io/example/demo-app 2>/dev/null \
     | grep -q 'NEW_RELIC_LICENSE_KEY'; then
    report pass "newrelic env injected in staging/prod, absent in dev"
  else
    report fail "newrelic env injection mismatch (want staging+prod yes, dev no)"
  fi
else
  report skip "helm and/or python3 not installed"
fi

# ----------------------------------------------------------------------------
section "5. YAML syntax (workflows, gitops, infra, chart values)"
if have python3 && python3 -c 'import yaml' 2>/dev/null; then
  if python3 - <<'PY'; then
import glob, sys, yaml
ok = True
skip = ("charts/demo-app/templates/",)  # Go-template syntax, rendered by helm
for f in sorted(glob.glob("**/*.yaml", recursive=True) + glob.glob("**/*.yml", recursive=True)):
    if f.startswith(skip):
        continue
    try:
        yaml.safe_load(open(f))
    except Exception as e:
        ok = False
        print(f"  invalid {f}: {e}")
sys.exit(0 if ok else 1)
PY
    report pass "yaml syntax valid for non-template files"
  else
    report fail "yaml syntax errors found"
  fi
else
  report skip "python3 with pyyaml not installed"
fi

# ----------------------------------------------------------------------------
section "6. ArgoCD manifests via kustomize"
if have kubectl; then
  kubectl kustomize infra/argocd >/tmp/opencode-test-kustomize.out 2>/tmp/opencode-test-kustomize.log \
    && report pass "kubectl kustomize infra/argocd" \
    || report fail "kubectl kustomize infra/argocd (see /tmp/opencode-test-kustomize.log)"
else
  report skip "kubectl not installed"
fi

# ----------------------------------------------------------------------------
section "7. GitHub Actions workflow validation (actionlint)"
if have actionlint; then
  actionlint .github/workflows/*.yaml >/tmp/opencode-test-actionlint.log 2>&1 \
    && report pass "actionlint on 5 workflows" \
    || report fail "actionlint (see /tmp/opencode-test-actionlint.log)"
else
  report skip "actionlint not installed (docs/testing.md describes installation)"
fi

# ----------------------------------------------------------------------------
section "8. Promotion/rollback scripts (e2e in scratch git repo)"
if have git && have python3 && python3 -c 'import yaml' 2>/dev/null; then
  SCRATCH="$(mktemp -d)"
  cp -r apps charts gitops scripts "$SCRATCH"
  if (cd "$SCRATCH" \
      && git init -q -b main \
      && git config user.email test@test && git config user.name test \
      && git add -A && git commit -qm v0 \
      && ./scripts/promote-image.sh demo-app prod ghcr.io/example/demo-app@sha256:feedface >/dev/null \
      && grep -q 'digest: sha256:feedface' gitops/environments/prod.yaml \
      && git checkout -q main \
      && git merge -q --no-ff "promotion/demo-app-prod" -m "merge promotion" \
      && grep -q 'digest: sha256:feedface' gitops/environments/prod.yaml \
      && ./scripts/rollback.sh demo-app prod --to-previous >/dev/null \
      && grep -q 'tag: latest' gitops/environments/prod.yaml \
        && ! grep -q 'digest: sha256:feedface' gitops/environments/prod.yaml); then
    report pass "promote-image.sh + rollback.sh e2e"
  else
    report fail "promote/rollback e2e (scratch repo: $SCRATCH)"
  fi
  rm -rf "$SCRATCH"
else
  report skip "git/python3/pyyaml not installed"
fi

# ----------------------------------------------------------------------------
echo
echo "== summary: pass=$PASS fail=$FAIL skip=$SKIP =="
exit $(( FAIL ? 1 : 0 ))